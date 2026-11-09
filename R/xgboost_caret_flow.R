#' Wrapper for XGBoost
#'
#' Tune, fits and tests XGBoost models with
#' k-fold cross-validation.
#'
#' @param dat a `data.table` containing predictors and response variable.
#' @param dig a digest passed to `Cache(..., .cacheExtra)` to bypass digesting
#'    `dat`. Often `dig` is a digest of `dat`.
#' @param nFolds number of folds for cross-validating the final model
#'    (i.e. the model using tuned parameters).
#' @param colnamesResp Name of column in `dat` to use as response variable.
#'    All other columns will be used as predictors
#' @param objective the objective function to use in `xgboost`
#' @param interaction_constraints passed to `xgboost::xgboost`.
#'    By default no interaction constraints.
#' @param eval_metric the metric by which to evaluate fit. 
#' @param SHAPthresh. Quantile threshold used for feature (i.e. variable) selection
#'    based on SHAP values. Features with SHAP values below the quantile threshold
#'    are excluded and the model re-run. A warning is issued if this resulted in poorer
#'    performace (based on AUC score), in which case one may consider relaxing (i.e. lowering)
#'    the threshold.
#' @param figDir if not `NULL`, diagnostic tuning plots will be saved to this directory.
#' @param cachePath directory to cache results - likely cachePath(sim) if running inside a simulation
#' @param nthreads number of CPU threads used by `xgboost`, both when tuning (via `caret`) and when fitting.
#'    `NULL` or `NA` uses `.defaultThreads()`, which leaves cores free for other users.
#'
#' @return a list (one entry per fold) of lists with:
#'   * `$mod`: fitted model
#'   * `shap_values`: SHAP values for the fitted model
#'   * `shap_long`: long version of the SHAP values for the fitted model (used for plotting)
#' @importFrom purrr pmap
#' @importFrom pROC roc
#' @importFrom crayon cyan
#' @importFrom SHAPforxgboost shap.values
#' @importFrom reproducible Cache
runXGBOOST <- function(dat, dig = NULL, nFolds = 5, colnamesResp = "SEV_PROP",
                       eval_metric = c("auc", "rmse", "logloss"),
                       objective = NULL, interaction_constraints = NULL, SHAPthresh = 0,
                       figDir = NULL, 
                       cachePath = NULL, nthreads = NULL) {

  nthreads <- .resolveThreads(nthreads)

  # Add dummy variables for factor columns -- i.e., the random effects
  if (all(sapply(dat, is.numeric)) %in% FALSE)
    dat <- model.matrix(~ . + 0, data = dat) |>
      Cache(cachePath = cachePath, omitArgs = c("object", "data", "x"),
            .cacheExtra = dig,
            userTags = c("gmcsDataPrep", "xgboostFit", "modelMatrix")) # Creates dummy variables
  
  dat <- as.data.table(dat)
  
  ## a year column only orders the time-ordered folds below; it is dropped, so it is not a predictor
  yearColname <- grep("year", colnames(dat), ignore.case = TRUE, value = TRUE)
  colnamesPred <- setdiff(colnames(dat), c(colnamesResp, yearColname)) ## after model.matrix bcs colnames change
  
  ## Setup k-folds -----
  ## leave the random number generator as it was found: .Random.seed exists only once it is used
  if (exists(".Random.seed", envir = .GlobalEnv, inherits = FALSE)) {
    savedSeed <- get(".Random.seed", envir = .GlobalEnv)
    on.exit(assign(".Random.seed", savedSeed, envir = .GlobalEnv), add = TRUE)
  } else {
    on.exit(rm(".Random.seed", envir = .GlobalEnv), add = TRUE)
  }
  set.seed(12345) # so kfolds are same, so Caching works correctly below; if dat changes number of rows,
  # it will be a totally different sequence; but it will be the same sequence
  # if number of rows doesn't change
  
  indexNames <- c("allData", "evalData")
  
  if (length(yearColname)) {
    crossValType <- "time-ordered"
    times <- unique(dat[[yearColname]])
    testLength <- 3
    initialWindow <- length(times) - testLength - nFolds + 1
    trainIndexK <- caret::createTimeSlices(times, initialWindow = initialWindow, testLength, fixedWindow = FALSE)
    trainIndexK <- Map(tr = trainIndexK$train, te = trainIndexK$test, function(tr, te) {
      allData <- which(dat[[yearColname]] %in% times[c(tr, te)])
      evalData <- which(dat[[yearColname]] %in% times[te])
      list(allData, evalData) |> setNames(indexNames)
    })
  } else {
    crossValType <- "crossValidation"
    ## create folds and make a list with indices of full dataset and each fold
    trainIndexK <- caret::createFolds(dat[[colnamesResp]], k = nFolds, list = TRUE, returnTrain = FALSE)
    trainIndexK <- Map(tr = trainIndexK, function(tr) {
      list(seq(NROW(dat)), tr) |> setNames(indexNames)
    })
  }
  
  ## sample columns after setting seed for caching (if different, then cache is triggered)
  colOrder <- setdiff(colnames(dat), c(yearColname))
  colOrder <- sample(colOrder)
  dat <- dat[, ..colOrder]
  dig <- .robustDigest(dat)
  
  ## Tune parameters on full data with caret first ----
  params <- .tunexgboost(dig,
                         dat[, .SD, .SDcols = c(colnamesPred, colnamesResp)],
                         colnamesResp = colnamesResp,
                         figDir, 
                         cachePath = cachePath,
                         nthreads = nthreads) |>
    # nthreads does not change the result, so it should not invalidate the cache
    Cache(cachePath = cachePath, userTags = c("gmcsDataPrep", "xgboostFit", "tuneXGBoost"),
          omitArgs = "nthreads")

  ## subset predictor data
  datPreds <- dat[, ..colnamesPred]
  
  st <- system.time(
    mm <- pmap(
      list(dataFolds = trainIndexK, kFold = seq(nFolds)),
      function(dataFolds, kFold) {
        ## get row IDs for training data (allData) and testing data
        allDataIDs <- dataFolds[[indexNames[[1]]]]
        testIDs <- dataFolds[[indexNames[[2]]]]   ## eval data
        dig2 <- .robustDigest(dataFolds)
        
        # xgboost objects do not save with `qs` ... must be `rds`
        # opt <- options(reproducible.cacheSaveFormat = "rds")
        # on.exit(options(opt)) # redundant; but necessary if it fails during fit
        lowSHAPcols <- 1
        calcThresh <- TRUE
        # SHAPthresh <- 0.25  ## test
        cols2keep <- colnames(datPreds)
        
        modOut <- NULL

        while (length(lowSHAPcols)) {
          ## TODO: test: go back to previous model if AUC decreases after removing features
          modOut2 <- xgboost(x = datPreds[allDataIDs],
                             , y = dat[[colnamesResp]][allDataIDs]
                             , interaction_constraints = interaction_constraints
                             # , objective = "reg:tweedie" ## no improvements
                             , nthread = nthreads
                             ## rows of `x`, not of `dat`: time-ordered folds train on a subset
                             , eval_set = match(testIDs, allDataIDs),
                             , monitor_training = TRUE
                             , eval_metric = eval_metric,
                             , early_stopping_rounds = 100
                             , max_depth = params$max_depth   ## improved fit.
                             , nrounds = params$nrounds
                             , learning_rate = params$eta
                             , min_split_loss = params$gamma
                             , min_child_weight = params$min_child_weight
                             , colsample_bytree = params$colsample_bytree
          )
          
          if (is.null(modOut)) {
            modOut <- modOut2
            RMSEout <- tail(attr(modOut, "evaluation_log"), 1)$train_rmse
          }

          ## get last RMSE
          RMSEout2 <- tail(attr(modOut2, "evaluation_log"), 1)$train_rmse
          if (RMSEout2 < RMSEout) {
            message("AUC decreased after removing features.\n",
                    "  The previous model will be retained, instead")
          } else {
            modOut <- modOut2
          }
          RMSEout <- RMSEout2
          
          ## calculate predictions and residuals
          valData <- datPreds[testIDs,]
          valData <- cbind(valData,
                           obs =  dat[[colnamesResp]][testIDs],
                           pred = predict(modOut, datPreds[testIDs, ]))
          valData[, resid := pred - obs]
          
          ## Feature selection -- remove features (variables) with low SHAP values
          ## based on a quantile threshold
          shap_values <- shap.values(modOut, datPreds) |>
            Cache(cachePath = cachePath, 
                  omitArgs = formalArgs(shap.values),
                  .functionName = .functionNameHelper("shap.values", "xgboost", kFold),
                  .cacheExtra = c(dig, dig2, cols2keep),
                  userTags = c("gmcsDataPrep", "xgboostFit", "shap"))
          meanSHAP <- shap_values$mean_shap_score
          
          if (calcThresh) {
            SHAPthresh <- quantile(meanSHAP, prob = SHAPthresh)
            calcThresh <- FALSE ## we only calculate the threshold once
          }
          
          lowSHAPcols <- names(which(meanSHAP < SHAPthresh))
          if (length(lowSHAPcols)) {
            cols2keep <- setdiff(colnames(datPreds), lowSHAPcols)
            datPreds <- datPreds[, ..cols2keep]
            
            message("Removing features with SHAP < ", SHAPthresh, ":\n",
                    paste(lowSHAPcols, collapse = ", "))
          }
          
        }
        
        ## more outputs
        shapContrib <- shap_values$shap_score
        shapContrib <- shapContrib[, -"(Intercept)"]
        shap_long <- shap.prep(shap_contrib = shapContrib, X_train = datPreds) |>
          Cache(cachePath = cachePath,
                omitArgs = formalArgs(shap.prep),
                .functionName = .functionNameHelper("shap.prep", kFold),
                .cacheExtra = c(dig, dig2, cols2keep),
                userTags = c("gmcsDataPrep", "xgboostFit", "shap"))

        list(valData = valData,
             mod = modOut,
             shap_values = shap_values,
             shap_long = shap_long)
      })
  )
  
  return(mm)
}

#' Tune XGBoost parameters with `caret`
#'
#' Tuning is done in 3 steps.
#' Step 1. Tune learning rate (called `learning_rate` in `xgboost`
#' and `eta` in `caret`)
#' Step 2. Take the best learning rate and tune all other parameters
#' (from those passed to `xgboost` by `[caret::train()]`) except
#' `rnounds` and `sample` (which is always kept as 1).
#' Step 3. Take the best parameters values from Steps 1 and 2 and tune
#' `nrounds`.
#'
#' @returns a data.frame of best parameter values.
#'
#' @inheritParams runXGBOOST
#' @importFrom reproducible Cache
.tunexgboost <- function(dig, dat, colnamesResp, figDir, cachePath, nthreads = 1L) {
  ## needs caret with xgboost 3.x support (topepo/caret#1543, which fixed #1412): on GitHub, not
  ## yet on CRAN
  savePlot <- FALSE
  if (!is.null(figDir)) {
    dir.create(figDir, showWarnings = FALSE, recursive = TRUE)
    savePlot <- TRUE
  }
  
  colnamesPred <- setdiff(colnames(dat), colnamesResp)
  
  ## Step 1. tune learning rate.
  ## eta = learning rate.
  param_grid1 <- data.frame(nrounds = 300,
                            eta = seq(0.01, 0.2, by =  0.005),
                            ## defaults in xgboost:
                            max_depth = 6,
                            gamma = 0,
                            colsample_bytree = 1,
                            min_child_weight = 1,
                            subsample = 1)
  
  xgb_trcontrol <- caret::trainControl(
    method = "cv",
    number = 5,
    verboseIter = TRUE,
    returnData = FALSE,
    returnResamp = "final",
    ## threads are set via `nthread` (passed to xgboost); a foreach backend on top would nest parallelism
    allowParallel = FALSE,
    savePredictions = "final"
  )
  message(cyan("Tuning learning rate..."))
  st <- system.time(
    {
      xgb_tuned <- caret::train(
        dat[[colnamesResp]] ~ .,
        data = as.data.frame(dat[, ..colnamesPred]),
        trControl = xgb_trcontrol,
        tuneGrid = param_grid1,
        method = "xgbTree",
        nthread = nthreads
      ) 
    }
  )
  
  paramsF <- xgb_tuned$bestTune
  message(cyan("Finished in", st[["elapsed"]], "sec."))
  
  ## save tuning output
  if (savePlot) {
    png(file.path(figDir, paste0(colnamesResp, "_tuning_learningRate.png")), height = 4, width = 6,
        units = "in", res = 300)
    lattice::trellis.par.set(caret::caretTheme())
    print(plot(xgb_tuned))
    dev.off()
  }
  
  ## Step 2. fix best learning rate and vary the rest
  param_grid2 <- expand.grid(nrounds = 200,
                             max_depth = c(1:10),
                             eta = paramsF$eta,
                             gamma = c(0, 0.1, 1, 2),#, 5, 10), ## tested with more initially, but not necessary
                             colsample_bytree = c(0.1, 0.5, 1),
                             min_child_weight = c(0, 1, 2, 5),
                             subsample = 1)
  
  ## tune other parameters
  for (i in 1:3) gc(reset = TRUE)
  message(cyan("Tuning remaining XGBoost parameters..."))

  st <- system.time(
    {
      xgb_tuned <- caret::train(x = as.data.frame(dat[, ..colnamesPred]),
                         y = dat[[colnamesResp]],
                         trControl = xgb_trcontrol,
                         tuneGrid = param_grid2,
                         method = "xgbTree",
                         nthread = nthreads
      )
    }
  )
  
  paramsF <- xgb_tuned$bestTune
  message(cyan("Finished in", st[["elapsed"]], "sec."))   ## about 4hrs
  
  ## save tuning output
  if (savePlot) {
    png(file.path(figDir, paste0(colnamesResp, "_tuning_all.png")), height = 12, width = 12,
        units = "in", res = 300)
    lattice::trellis.par.set(caret::caretTheme())
    print(plot(xgb_tuned))
    dev.off()
  }
  
  ## Step 3. vary only no. rounds
  param_grid3 <- expand.grid(nrounds = c(100, 200, 500, 1000, 1500, 2000),
                             max_depth = paramsF$max_depth,
                             eta = paramsF$eta,
                             gamma = paramsF$gamma,
                             colsample_bytree = paramsF$colsample_bytree,
                             min_child_weight = paramsF$min_child_weight,
                             subsample = 1)
  
  ## tune other parameters
  for (i in 1:3) gc(reset = TRUE)
  message(cyan("Tuning no. rounds (trees)..."))
  st <- system.time(
    {
      xgb_tuned <- caret::train(x = as.data.frame(dat[, ..colnamesPred]),
                         y = dat[[colnamesResp]],
                         trControl = xgb_trcontrol,
                         tuneGrid = param_grid3,
                         method = "xgbTree",
                         nthread = nthreads
      )
    }
  )
  
  paramsF <- xgb_tuned$bestTune
  message(cyan("Finished in", st[["elapsed"]], "sec."))
  message(cyan("Best parameters:"))
  message(cyan(paste0(capture.output(paramsF), collapse = "\n")))
  
  ## save tuning output
  if (savePlot) {
    png(file.path(figDir, paste0(colnamesResp, "_tuning_nrounds.png")), height = 4, width = 6,
        units = "in", res = 300)
    lattice::trellis.par.set(caret::caretTheme())
    print(plot(xgb_tuned))
    dev.off()
  }
  
  for (i in 1:3) gc(reset = TRUE)
  return(paramsF)
}

#' Default number of threads for `xgboost`
#'
#' `xgboost` uses every core unless told otherwise. This uses a fraction of the cores that are
#' currently free (available cores less the current 1-minute load), so that other users or processes
#' sharing the machine are not starved. Where the load is unknown (e.g., Windows), one core is
#' assumed to be busy.
#'
#' @param fraction fraction of the currently free cores to use.
#' @return an integer >= 1.
#' @importFrom parallelly availableCores
#' @keywords internal
.defaultThreads <- function(fraction = 0.5) {
  avail <- parallelly::availableCores()
  load1 <- suppressWarnings(tryCatch(
    as.numeric(strsplit(readLines("/proc/loadavg", n = 1L), " ")[[1]][1]),
    error = function(e) NA_real_))
  busy <- if (is.na(load1)) 1 else ceiling(load1)
  max(1L, as.integer(floor((avail - busy) * fraction)))
}

#' Resolve the `nthreads` parameter
#'
#' @param nthreads `NULL`/`NA` for the default (see `.defaultThreads()`), or a number of threads.
#' @return an integer >= 1.
#' @keywords internal
.resolveThreads <- function(nthreads = NULL) {
  if (is.null(nthreads) || length(nthreads) != 1L || is.na(nthreads)) {
    nthreads <- .defaultThreads()
    message("gmcsDataPrep: using ", nthreads, " thread(s) for xgboost (default; set the `nthreads` parameter to change)")
  } else {
    nthreads <- max(1L, as.integer(nthreads))
    avail <- parallelly::availableCores()
    if (nthreads > avail)
      warning("nthreads (", nthreads, ") is more than the cores available (", avail, ")", call. = FALSE)
  }
  nthreads
}

.functionNameHelper <- function(..., sep = "_") {
  paste(..., sep = sep)
}

# shap.plot.dependence(data_long = growthMod_kfold$Fold1$shap_long,
#                      x = 'psp_sppPinu_con',
#                      y = 'MAT',
#                      dilute = 0) +
#   ggtitle("SHAP for pine | DD_O")

