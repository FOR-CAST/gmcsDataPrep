defineModule(sim, list(
  name = "gmcsDataPrep",
  description = "Prepare data to provide grow and mortality (climate-sensitve) adjustments for LandR.CS",
  keywords = c("LandR", "LandR.CS"),
  authors = c(
    person(c("Ian", "MS"), "Eddy", email = "ian.eddy@nrcan-rncan.gc.ca", role = c("aut", "cre")),
    person(c("Alex", "M"), "Chubaty", email = "achubaty@for-cast.ca", role = "ctb")
  ),
  childModules = character(0),
  version = list(gmcsDataPrep = "0.0.2.9000"),
  timeframe = as.POSIXlt(c(NA, NA)),
  timeunit = "year",
  citation = list("citation.bib"),
  documentation = list("README.txt", "gmcsDataPrep.Rmd"),
  reqdPkgs = list("crayon", "data.table", "ggplot2", "lightgbm",
                  "parallelly", "purrr", "pROC", "sf", "xgboost (>= 3.0.5.1)",
                  # fork of caret that works with xgboost >= 3.0.5.1; revisit if topepo/caret#1412 is fixed upstream
                  "ceresbarros/caret/pkg/caret",
                  #maybe install.packages('xgboost', repos = c('https://dmlc.r-universe.dev', 'https://cloud.r-project.org'))
                  "PredictiveEcology/LandR@development (>= 1.1.4)",
                  "ianmseddy/LandR.CS@development (>= 0.0.3.9000)",
                  "PredictiveEcology/reproducible (>= 2.1.0)",
                  "PredictiveEcology/pemisc@development (>= 0.0.4.9015)",
                  "ianmseddy/PSPclean@development (>= 1.0.0.9006)",
                  "PredictiveEcology/SHAPforxgboost (>= 0.1.3.9001)"),
  parameters = rbind(
    #defineParameter("paramName", "paramClass", value, min, max, "parameter description"),
    defineParameter("biomassModel", "character", "Lambert2005", NA, NA,
                    desc =  paste("The model used to calculate biomass from DBH.",
                                  "Can be either 'Lambert2005' or 'Ung2008'.")),
    defineParameter("climateNormal", "numeric", c(1991:2020), NA, NA,
                    desc = paste("length 2 numeric denoting the first and last years to use when calculating anomaly variables.",
                                 "This date range should match the data used to estimate maxANPP and maxB, if applicable.")),
    #TODO: review this parameter once the climate normal data is avaiable for PSPs (currently only 2001-2020 via climr)
    defineParameter("doAssertion", "logical", getOption("LandR.assertions"), NA, NA,
                    desc = "assertions used to check climate data for NA values in valid pixels"),
    defineParameter("doPlotting", "logical", TRUE, NA, NA, 
                    desc = paste("if true, will plot and save models")),
    defineParameter("nthreads", "numeric", NA, 1, NA,
                    desc = paste("Number of CPU threads used by xgboost when tuning (via caret) and fitting the growth and",
                                 "mortality models. `NA` (the default) uses half of the cores that are currently free",
                                 "(available cores less the current load, minimum 1), so other users of the machine are",
                                 "not starved. Changing it does not invalidate the cached models.")),
    defineParameter("growthKFolds", "numeric", 5, 0, Inf, 
                    desc = paste("number of K-folds applied to xgBoost climate-sensetive growth model")),
    defineParameter("maxDBHperYear", "numeric", 1, 0, Inf, 
                    paste("Q/C parameter dictating maximum expected increase in DBH per year for newly measured trees,", 
                          "above which measurements are treated as erroneous and removed from the dataset")),
    defineParameter("maxIntervalPeriod", "numeric", 10, 1, Inf, 
                    paste("the maximum length of measurement interval to allow before discarding an observation.", 
                          "The climate is averaged between measurements, so the longer the interval, the more noise")),
    defineParameter("minDBH", "numeric", 9.7, 0, NA,
                    desc = "The minimum DBH (cm) allowed. Each province uses different criteria for monitoring trees,
                    so a conservative threshold is advised The following are approximations: ",
                    "Ontario = 2.5 cm (after 1991), Alberta = 7.3, SK = 9.7 and 7.1 before/after 1977, BC = 4,",
                    "QC = 9, NB = 5, NFI = 9"),
    defineParameter("minMeasures", "numeric", 2, 2, Inf,
                    desc = paste0("the minimum number of measurements per plot. Each pair of measurements",
                                  "generates one observation of growth and mortality")),
    defineParameter("minTrees", "numeric", 30, 0, NA,
                    desc = paste("The minimum number of trees per initial plot.",
                                 "This is prior to filtering by minimum DBH.",
                                 "This may not be suitable for every use case.
                                 The default is 30, based on the GCB paper <doi: 10.1111/gcb.12994>.")),
    defineParameter("minSampleForSpecies", "numeric", 1000, 0, NA,
                    desc = paste("the minimum number of observations of tree species within stands below which",
                                 "they are combined as a single category of 'other spp' in the climate-sensitive models")),
    defineParameter("minSize", "numeric", 0.02, 0, NA,
                    desc = paste("The minimum size (in hectares) of growth plot. All metrics are adjusted for area.",
                                 "The canonical methodology did not force a minimum size but the minimum size was 0.04 ha.")),
    defineParameter("mortalityKFolds", "numeric", 5, 0, Inf, desc = paste("number of K-folds applied to xgBoost climate-sensetive mortality model")),
    defineParameter("PSPdataTypes", "character", "all", NA, NA,
                    desc = paste("Which PSP datasets to source, defaulting to all. Other available options include",
                                 "'BC', 'AB', 'SK', 'NFI', 'ON', 'NB', and 'dummy'. 'dummy' is for unauthorized users.")),
    defineParameter("PSPperiod", "numeric", c(1900, 2025), NA, NA,
                    desc = paste("The measurement years by which to subset sampling plot data, if any",
                                 "Must be a vector of at least length 2.")),
    defineParameter("PSPvalidationPeriod", "numeric", NULL, NA, NA,
                    desc = paste("the period to build the validation dataset. Must be greater than PSPperiod",
                                 "e.g. c(1958-2018). Subsequent observations are used only if they are within this period,",
                                 "but outside the fitting period. E.g. Successive measurements in 2004 and 2017",
                                 "would be used even though the first measurement falls outside the 2011 fitting period",
                                 "as the 2011 cutoff would remove this paired obsevation from the fitting data.",
                                 "If NULL, then validation dataset will instead be randomly sampled from available measurements.")),
    defineParameter("QCaction", "numeric", 1, 0, 4,
                    desc = paste("Level of quality control to apply based on assessTreeNumberConsistency. Each level is additive",
                                 "so that level 4 performs the actions of levels 1, 2, 3, and 4:",
                                 "0 = no action;",
                                 "1 = remove all measurements flagged as problematic and any subsequent measurements within those plots;",
                                 "2 = remove problematic trees from all measurements, keeping other trees in those measurements/plots;",
                                 "3 = remove all plots that contain any problematic measurements;",
                                 "4 - remove all plots that contain any problematic measurements OR problematic trees.")),
    defineParameter("sppEquivCol", "character", "LandR", NA, NA,
                    desc = paste("the column in `LandR::sppEquivalencies_CA` to use for standardizing PSP names.",
                                 "Note that biomass is estimated from tree plot data using the column `PSP`.",
                                 "Combining the models for species with separate biomass equations (e.g. Populus balsamea, Populus treumuloides)",
                                 "is possible by passing a sppEquivCol that has a single value for these entries.")),
    defineParameter("useHeight", "logical", TRUE, NA, NA,
                    desc = paste("Use height be used to calculate biomass (in addition to DBH). If height is NA for individual",
                                 "trees, then only DBH will be used for those measurements")),
    defineParameter(".useCache", "character", ".inputObjects", NA, NA,
                    desc = paste("Should this entire module be run with caching activated?",
                                 "This is generally intended for data-type modules,",
                                 "where stochasticity and time are not relevant.")),
    defineParameter(".runName", "character", NA_character_, NA, NA,
                    paste('Name for simulation provided by user. Used as a title for diagnostic plots',
                          'NULL is allowed but will result in plots without titles.'))
  ),
  inputObjects = bindrows(
    #expectsInput("objectName", "objectClass", "input object description", sourceURL, ...),
    expectsInput(objectName = "PSPmeasure_gmcs", objectClass = "data.table", desc = "standardized tree measurements for PSPs",
                 sourceURL = "https://drive.google.com/file/d/1LmOaEtCZ6EBeIlAm6ttfLqBqQnQu4Ca7/"),
    expectsInput(objectName = "PSPplot_gmcs", objectClass = "data.table", desc = "standardized plot-level attributes for PSPs",
                 sourceURL = "https://drive.google.com/file/d/1LmOaEtCZ6EBeIlAm6ttfLqBqQnQu4Ca7/"),
    expectsInput(objectName = "PSPgis_gmcs", objectClass = "data.table", desc = "PSP plot data as sf object",
                 sourceURL = "https://drive.google.com/file/d/1LmOaEtCZ6EBeIlAm6ttfLqBqQnQu4Ca7/"),
    expectsInput(objectName = "PSPclimData", objectClass = "data.table",
                 desc = paste("climate data for each PSP from ClimateNA. Temp is represented in degrees Celsius.",
                              "see https://climatena.ca/Help2 for details."),
                 sourceURL = "https://drive.google.com/file/d/1KFkX6bVCzwEA6V9MQEWqXxIEnON6YerN/view?usp=drive_link"),
    expectsInput(objectName = "studyAreaPSP", objectClass = "SpatVector",
                 desc = paste("Optional area used to subset PSP plots before building the statistical models.",
                              "Any class of spatial object is acceptable."), sourceURL = NA),
    expectsInput(objectName = "sppEquiv", objectClass = "data.table",
                 desc = "Table of species equivalencies. See `LandR::sppEquivalencies_CA`"),
    expectsInput("sppEquiv", "data.table",
                 desc = paste("table of species equivalencies - see `?LandR::sppEquivalencies_CA`",
                              "unique observations of <sppEquivCol> will be included as in the climate-sensitive model",
                              "as a factor covariate (converted to dummy for xgboost)")),
    expectsInput("sppEquivLong", "data.table",
                 desc = paste("The full table of species equivalencies - see `?LandR::sppEquivalencies_CA`.",
                              "Biomass will be estimated for each species based on the `sp_Biomass_eq' column,",
                              "which uses `pemisc::biomassCalculation` to derive AGB from DBH and height",
                              "(based on the equations from https://doi.org/10.1139/x05-112). The full table",
                              "is used to improve stand biomass estimates even if some species are not of interest.")),
  ),
  outputObjects = bindrows(
    createsOutput(objectName = "gcsModel", objectClass = "list",
                  desc = "growth model with covariates indicated by sim$climateVariablesForGMCS, biomass, and log(age)"),
    createsOutput(objectName = "mcsModel", objectClass = "list",
                  desc = "mortality model with covariates indicated by sim$climateVariablesForGMCS, biomass, and log(age)"),
    createsOutput(objectName = "PSPmodelData", objectClass = "data.table",
                  desc = "PSP growth mortality calculations"),
    createsOutput(objectName = "gcsShapScores", objectClass = "data.table",
                  desc = paste("Mean absolute SHAP scores per variable averaged across cross-validation folds",
                               "for the climate-sensitive growth model (gcsModel) saved as a .csv")),
    createsOutput(objectName = "mcsShapScores", objectClass = "data.table",
                  desc = paste("Mean absolute SHAP scores per variable averaged across cross-validation folds",
                               "for the climate-sensitive mortality model (mcsModel) saved as a .csv"))
  )
))

## event types
#   - type `init` is required for initialization

doEvent.gmcsDataPrep = function(sim, eventTime, eventType) {
  switch(
    eventType,
    init = {
      # do stuff for this event
      sim <- Init(sim)
    },
    warning(paste("Undefined event type: '", current(sim)[1, "eventType", with = FALSE],
                  "' in module '", current(sim)[1, "moduleName", with = FALSE], "'", sep = ""))
  )
  return(invisible(sim))
}

### template initialization
Init <- function(sim) {

  if (is.null(sim$mcsModel) | is.null(sim$gcsModel)) {
    message("building climate-sensitive growth and mortality models")

    #checks
    if (length(P(sim)$PSPperiod) < 2) {
      stop("Please supply P(sim)$PSPperiod of length 2 or greater")
    }

    if (any(is.null(sim$PSPmeasure_gmcs), is.null(sim$PSPplot_gmcs), is.null(sim$PSPgis_gmcs))) {
      stop("The PSP objects are being supplied incorrectly. Please review loadOrder argument in simInit")
    }

    #TODO: do this manually for now until Jonathan's changes materialize
    #PSP will become SpBiomassEq
    temp <- unique(sim$sppEquivLong[, .SD, .SDcol = c("PSP", "Latin_full", P(sim)$sppEquivCol)])
    setnames(temp, old = "PSP", new = "SpBiomassEq")
    sim$PSPmeasure_gmcs <- temp[sim$PSPmeasure_gmcs, on = c("Latin_full" = "Species")]
    setnames(sim$PSPmeasure_gmcs, old = P(sim)$sppEquivCol, new = c("Species"))
    sim$PSPmeasure_gmcs[is.na(SpBiomassEq), SpBiomassEq := ""] #currently required by pemisc
    #numeric from plotID
    #this should be done before creating modelData so the factors aren't duplicated in the validation set
    sim$PSPplot_gmcs[, plotNumeric := as.numeric(as.factor(OrigPlotID1))]

    
    # SK From 1958/1964 to 1976 breakpoint DBH was 3.6” at 4.5’ (approximately 9.2cm at 1.3m).
    #Starting in 1977 the breakpoint DBH became 7.1cm DBH at 1.3m. Approximately 2% of the half-million
    #trees in the data have a DBH which is below the breakpoint DBH, but have been retained in the data
    #as they may represent remeasurements of previously tagged trees, or dead trees for which bark shedding has reduced
    #the over-bark diameter Ontario = 2.5 cm (after 1991), Alberta = 7.3, SK = 7.1, BC = 4, and NFI = 9, NB, QC.
    sim$PSPmodelData <- prepModelData(
      climateVariables = sim$climateVariablesForGMCS,
      studyAreaPSP = sim$studyAreaPSP,
      PSPgis = sim$PSPgis_gmcs,
      PSPmeasure = sim$PSPmeasure_gmcs,
      PSPplot = sim$PSPplot_gmcs,
      PSPclimData = sim$PSPclimData,
      useHeight = P(sim)$useHeight,
      biomassModel = P(sim)$biomassModel,
      climateNormal = P(sim)$climateNormal,
      PSPperiod = P(sim)$PSPperiod,
      minDBH_tag = P(sim)$minDBH,
      minMeasures = P(sim)$minMeasures,
      minSize = P(sim)$minSize,
      minTrees = P(sim)$minTrees,
      max_DBH_year = P(sim)$maxDBHperYear,
      maxInterval = P(sim)$maxIntervalPeriod,
      QCaction = P(sim)$QCaction) |>
      Cache(userTags = c("gmcsDataPrep", "prepModelData"))

    PSPmodelData <- sim$PSPmodelData

    #TODO: decide if this exclusion should occur in object saved by sim
    #take only species of interest (ie in sim$sppEquiv)
    PSPmodelData[, N := .N, .(spp)]
    PSPmodelData <- PSPmodelData[N > P(sim)$minSampleForSpecies,]
    #TODO: set aside some for validation - unclear if necessary

    #Prepare Data for XGBoost
    anomalyVariables <- setdiff(names(sim$climateVariablesForGMCS), "")
    allClimVar <- c(sim$climateVariablesForGMCS, anomalyVariables)

    #need to remove non-useful columns due to use of categorical data
    #don't add mortality or it will be treated as a covariate
    PSPmodelData <- PSPmodelData[, .SD,
                                 .SDcols = c("logGrowth", "mortality", allClimVar,
                                             "biomass", "logAge", "standBiomass", "spp")]

    # Add dummy variables for factor columns -- i.e., the random effects
    if (all(sapply(PSPmodelData, is.numeric)) %in% FALSE)
      PSPmodelData <- model.matrix(~ . + 0, data = PSPmodelData)
    PSPmodelData <- as.data.table(PSPmodelData)

    #sum biomass and stand age within a pixelGroup

    colnamesPred <- setdiff(colnames(PSPmodelData), "logGrowth") ## after model.matrix bcs colnames change

    # module-safe figure directories
    gDir <- file.path(outputPath(sim), "figures", "gmcsDataPrep", "growth")
    checkPath(gDir, create = TRUE)
    mDir <- file.path(outputPath(sim), "figures", "gmcsDataPrep", "mortality")
    checkPath(mDir, create = TRUE)

    ## model building
    nthreads <- .resolveThreads(P(sim)$nthreads)

    ## only replace the models if NULL, so user can supply their own models
    if (is.null(sim$gcsModel)) {

      #drop mortality (hence copy)
      xgbTrainData_g <- copy(PSPmodelData)
      xgbTrainData_g[, mortality := NULL]

      #hyperparameter tuning and kfold cross validation
      sim$gcsModel <- runXGBOOST(dat = xgbTrainData_g,
                                 dig = NULL,
                                 nFolds = P(sim)$growthKFolds,
                                 eval_metric = c("rmse"),
                                 colnamesResp = "logGrowth",
                                 figDir = gDir,
                                 cachePath = cachePath(sim),
                                 nthreads = nthreads) |>
        Cache(userTags = c("gmcsDataPrep", "xgboostFit", "growthModel"), omitArgs = "nthreads")
      # compute mean R² across folds, save to simList
      ggGrowth <- lapply(sim$gcsModel, function(x){x$valData}) |> data.table::rbindlist()
      ggGrowth[, obs := exp(obs)]
      ggGrowth[, pred := exp(pred)]
      sim$gcsModel_r2 <- r2Fun(ggGrowth)

      message("r-squared for climate-sensitive growth model is: ", sim$gcsModel_r2)

      rm(xgbTrainData_g)
    }

    if (is.null(sim$mcsModel)) {

      #drop growth (hence copy)
      xgbTrainData_m <- copy(PSPmodelData)
      xgbTrainData_m[, logGrowth := NULL]

      #hyperparameter tuning and kfold cross validation
      sim$mcsModel <- runXGBOOST(dat = xgbTrainData_m,
                                 dig = NULL,
                                 nFolds = P(sim)$mortalityKFolds,
                                 objective = "reg::tweedie",
                                 eval_metric = c("rmse"),
                                 colnamesResp = "mortality",
                                 figDir = mDir,
                                 cachePath = cachePath(sim),
                                 nthreads = nthreads) |>
        Cache(userTags = c("gmcsDataPrep", "xgboostFit", "mortalityModel"), omitArgs = "nthreads")

      # compute mean R² across folds, save to simList
      ggMortality <- lapply(sim$mcsModel, function(x){x$valData}) |> data.table::rbindlist()
      sim$mcsModel_r2 <- r2Fun(ggMortality)

      message("r-squared for climate-sensitive mortality model is: ", sim$mcsModel_r2)

      rm(xgbTrainData_m)
    }

    if (is.na(P(sim)$.runName)) {
      runName <- NULL
    } else {
      runName <- P(sim)$.runName
    }

    sim$gcsShapScores <- lapply(sim$gcsModel, function(x) {
      out <- x$shap_values$mean_shap_score
      data.table(variable = names(out), shap_score = out)
    }) |>
      rbindlist()

    gcsShapPath <- file.path(outputPath(sim), paste0("gcsShapScores.csv"))
    data.table::fwrite(sim$gcsShapScores, file = gcsShapPath)
    message("Growth model SHAP scores saved to: ", gcsShapPath)

    sim$mcsShapScores <- lapply(sim$mcsModel, function(x) {
      out <- x$shap_values$mean_shap_score
      data.table(variable = names(out), shap_score = out)
    }) |>
      rbindlist()

    mcsShapPath <- file.path(outputPath(sim), paste0("mcsShapScores.csv"))
    data.table::fwrite(sim$mcsShapScores, file = mcsShapPath)
    message("Mortality model SHAP scores saved to: ", mcsShapPath)

    #Diagnostic Plotting
    if (P(sim)$doPlotting) {

      plotDir <- file.path(outputPath(sim), "figures", "gmcsDataPrep")
      checkPath(plotDir, create = TRUE)

      pGrowthVal <- ggplot(ggGrowth, aes(x = obs, y = pred)) +
        geom_bin2d() +
        geom_abline(slope = 1, intercept = 0, colour = "red", linetype = "dashed") +
        labs(title = paste0(runName,"\nGrowth model: observed vs. predicted (R² = ", round(sim$gcsModel_r2, 3), ")"),
             x = "Observed growth (g/m²)",
             y = "Predicted growth (g/m²)") +
        theme_minimal()

      ggsave(file.path(gDir, "gcsModel_obsVpred.png"), pGrowthVal,
             width = 7, height = 6, dpi = 150)

      pMortVal <- ggplot(ggMortality, aes(x = obs, y = pred)) +
        geom_bin2d() +
        geom_abline(slope = 1, intercept = 0, colour = "red", linetype = "dashed") +
        labs(title = paste0(runName,"\nMortality model: observed vs. predicted (R² = ", round(sim$mcsModel_r2, 3), ")"),
             x = "Observed mortality (g/m²)",
             y = "Predicted mortality (g/m²)") +
        theme_minimal()

      ggsave(file.path(mDir, "mcsModel_obsVpred.png"), pMortVal,
             width = 7, height = 6, dpi = 150)

      pPSPscatter <- ggplot(sim$PSPmodelData, aes(y = mortality, x = growth)) +
        geom_bin2d() +
        labs(
          title = paste0(runName,"\nGrowth vs. Mortality Observed in PSP data"),
          y = "Mortality (g/m²)",
          x = "Growth (g/m²)"
        ) +
        theme_minimal()

      ggsave(file.path(plotDir, "Growth_vs_mortality.png"), pPSPscatter,
             width = 7, height = 6, dpi = 150)
      message("Plots saved to: ", plotDir)
    }
  }

  return(invisible(sim))
}

prepModelData <- function(climateVariables, climateNormal, studyAreaPSP, PSPgis,
                          PSPmeasure, PSPplot, PSPclimData, useHeight, biomassModel,
                          max_DBH_year, PSPperiod, minDBH_tag, minMeasures, minSize, 
                          maxInterval, minTrees, QCaction) {

  #this is necessary for restartSpades to work if the error occurs in this module
  PSPmeasure <- copy(PSPmeasure)
  PSPplot <- copy(PSPplot)

  message(yellow("There are", nrow(PSPgis), "initial PSPs"))
  ## crop points to studyAreaPSP
  if (!is.null(studyAreaPSP)) {
    message(yellow("Filtering PSPs to study Area..."))
    #TODO: confirm this postProcess works
    PSP_sa <- reproducible::postProcess(PSPgis, maskTo = studyAreaPSP)
    message(yellow(paste0("There are "), nrow(PSP_sa), " PSPs in your study area"))
  } else {
    PSP_sa <- PSPgis
  }
  #Restrict climate variables to only those of interest.. should be param

  #Filter other PSP datasets to those in study Area
  PSPmeasure <- PSPmeasure[OrigPlotID1 %in% PSP_sa$OrigPlotID1,]
  PSPplot <- PSPplot[OrigPlotID1 %in% PSP_sa$OrigPlotID1,]
  PSPclimData <- PSPclimData[OrigPlotID1 %in% PSP_sa$OrigPlotID1,]

  
  #Filter out trees smaller than minDBH 
  message(yellow("Filtering by min. DBH"))
  
  #filter out plots where the DBH tagging limit might be larger than minDBH
  cutoffTooBig <- PSPplot[minDBH > minDBH_tag]$MeasureID
  message("removing ", length(cutoffTooBig), " plots with DBH tagging limits above P(sim)$minDBH")
  PSPmeasure <- PSPmeasure[!MeasureID %in% cutoffTooBig,]
  PSPplot <- PSPplot[!MeasureID %in% cutoffTooBig,]
  
  #Filter bad trees, measurements, or plots
  if (QCaction > 0) {
    message("Assessing tree number consistency across PSP measurements...")

    qcResult <- assessTreeNumberConsistency(
      plots = list(PSPplot = PSPplot, PSPmeasure = PSPmeasure),
      max_assumed_growth_rate = max_DBH_year
    )

    problematicTrees        <- qcResult$problematicTrees
    problematicMeasurements <- as.character(qcResult$problematicMeasurements)

    # Capture pre-filter counts for reporting
    nPlots_before <- uniqueN(PSPplot$OrigPlotID1)
    nMeas_before  <- uniqueN(PSPmeasure$MeasureID)
    nTrees_before <- nrow(PSPmeasure)

    # Apply QC level 1 if QCaction >= 1
    if (QCaction >= 1) {
      # Remove the flagged measurements and ALL later measurements in those plots
      #the problematic measurements already include subsequent measurements following 100% regen 
      flaggedMeas <- PSPmeasure[MeasureID %in% problematicMeasurements,]
      PSPmeasure <- PSPmeasure[!MeasureID %in% problematicMeasurements,]
    }

    # Apply QC level 2 if QCaction >= 2
    if (QCaction >= 2) {
      # Remove only the flagged trees; keep all other trees and measurements
      # in those plots/measurements untouched.
      #confirm this removes from all MeasureIDs (including subsequent)
      PSPmeasure <- PSPmeasure[!problematicTrees, on = .(OrigPlotID1, TreeNumber)]
    }

    # Apply QC level 3 if QCaction >= 3
    if (QCaction >= 3) {
      # Remove any plot that ever had a bad measurement
      badPlots <- unique(as.character(
        PSPmeasure[MeasureID %in% problematicTrees, OrigPlotID1]
      ))

      PSPmeasure <- PSPmeasure[!(as.character(OrigPlotID1) %in% badPlots)]
      PSPplot <- PSPplot[!(as.character(OrigPlotID1) %in% badPlots)]
    }

    # Apply QC level 4 if QCaction >= 4
    if (QCaction >= 4) {
      # Remove any plot that ever had a bad measurement OR a bad tree
      badPlots_fromMeas <- unique(as.character(
        PSPmeasure[MeasureID %in% problematicMeasurements, OrigPlotID1]
      ))
      badPlots_fromTrees <- unique(as.character(problematicTrees$OrigPlotID1))
      badPlots <- unique(c(badPlots_fromMeas, badPlots_fromTrees))

      PSPmeasure <- PSPmeasure[!(as.character(OrigPlotID1) %in% badPlots)]
      PSPplot <- PSPplot[!(as.character(OrigPlotID1) %in% badPlots)]
    }

    nPlots_after <- uniqueN(PSPplot$OrigPlotID1)
    nMeas_after  <- uniqueN(PSPmeasure$MeasureID)
    nTrees_after <- nrow(PSPmeasure)

    percent_removed <- function(before, after) {
      if (before <= 0 || !is.finite(before) || !is.finite(after)) {
        return("NA")
      }
      paste0(round(100 * (before - after) / before, 1), "%")
    }

    message(
      "QCaction = ", QCaction, " filtering complete:\n",
      "  Plots removed:        ", percent_removed(nPlots_before,  nPlots_after),  "\n",
      "  Measurements removed: ", percent_removed(nMeas_before,   nMeas_after),   "\n",
      "  Trees removed:        ", percent_removed(nTrees_before,  nTrees_after)
    )
  } else {
    message("QCaction = 0: skipping tree number consistency assessment.")
  }
  
  #remove trees where DBH falls below the standardized parameter minDBH_tag
  PSPmeasure <- PSPmeasure[DBH >= minDBH_tag,]
  
  ## might as well drop species with no biomass match

  ## `length(PSPclimData)/length(PSP_sa)` should always yield a whole number.
  ## Filter data by study period
  message(yellow("Filtering by study period..."))
  PSPmeasure <- PSPmeasure[MeasureYear > min(PSPperiod) &
                             MeasureYear < max(PSPperiod),]
  PSPplot <- PSPplot[MeasureYear > min(PSPperiod) &
                       MeasureYear < max(PSPperiod),]
  PSPclimData[Year > min(PSPperiod) & Year < max(PSPperiod),]
  message(yellow(paste0("There are "), length(unique(PSPplot$OrigPlotID1)), " PSPs in the study period"))
  ## Join data (should be small enough by now)
  PSPplot <- PSPplot[MeasureID %in% PSPmeasure$MeasureID,] #drop any measurements that have been remoevd
  PSPmeasure <- PSPmeasure[PSPplot, on = c('MeasureID', 'OrigPlotID1', 'MeasureYear', 'source')]

  ## Restrict to trees > minDBH

  ## Filter by min size
  message(yellow("Filtering by min. plot size"))
  bigEnough <- PSPplot[PlotSize > minSize, .N, .(OrigPlotID1)]
  PSPplot <- PSPplot[OrigPlotID1 %in% bigEnough$OrigPlotID1]
  message(yellow("There are ", nrow(bigEnough), " plots meeting the minimum plot size"))

  ## subset by biomass, because some plots have no species that can be estimated
  ## these will be counted in the min trees requirement,
  #but may result in a plot of NA biomass if repeat measures = 2+
  if (useHeight) {
    PSPmeasureNoHeight <- PSPmeasure[is.na(Height)]
    PSPmeasureHeight <- PSPmeasure[!is.na(Height)]
    tempOut <- biomassCalculation(species = PSPmeasureHeight$SpBiomassEq,
                                  DBH = PSPmeasureHeight$DBH,
                                  height = PSPmeasureHeight$Height,
                                  includeHeight = TRUE,
                                  equationSource = biomassModel)
    ## check if height is missing, join if so -- function fails if data.table is empty
    if (nrow(PSPmeasureNoHeight) > 0) {
      tempOutNoHeight <- biomassCalculation(species = PSPmeasureNoHeight$SpBiomassEq,
                                            DBH = PSPmeasureNoHeight$DBH,
                                            height = PSPmeasureNoHeight$Height,
                                            includeHeight = FALSE,
                                            equationSource = biomassModel)
      tempOut$biomass <- c(tempOut$biomass, tempOutNoHeight$biomass)
      tempOut$missedSpecies <- unique(c(tempOut$missedSpecies, tempOutNoHeight$missedSpecies))
      PSPmeasure <- rbind(PSPmeasureHeight, PSPmeasureNoHeight)
    }

    PSPmeasure[, biomass := tempOut$biomass]
    setkey(PSPmeasure, MeasureID, OrigPlotID1, TreeNumber)
  } else {
    tempOut <- biomassCalculation(species = PSPmeasure$SpBiomassEq,
                                  DBH = PSPmeasure$DBH,
                                  height = PSPmeasure$Height,
                                  includeHeight = FALSE,
                                  equationSource = biomassModel)
    PSPmeasure$biomass <- tempOut$biomass
  }

  #remove these measures as their inclusion only complicates code for no benefit
  PSPmeasure <- PSPmeasure[biomass > 0]
  PSPplot <- PSPplot[MeasureID %in% PSPmeasure$MeasureID]

  ## Filter by > minTrees at first measurement (P) to ensure forest. Default 30
  # This MUST occur after trees without biomass are removed, or you may have no trees to measure
  message(yellow("Filtering by minimum trees in earliest measurement"))

  forestPlots <- PSPmeasure[MeasureYear == baseYear, .(measures = .N), OrigPlotID1] %>%
    .[measures >= minTrees,]
  PSPmeasure <- PSPmeasure[OrigPlotID1 %in% forestPlots$OrigPlotID1,]
  PSPplot <- PSPplot[OrigPlotID1 %in% PSPmeasure$OrigPlotID1,]
  repeats <- PSPplot[, .(measures = .N), by = OrigPlotID1]
  message(yellow(paste0("There are "), nrow(repeats), " PSPs with min.", minTrees, " trees at earliest measurement"))

  ## Filter by 3+ repeat measures - must be last filter criteria.
  ## Some plots share ID but have different trees so simple count of plots insufficient to find repeat measures
  ## Reduce PSPmeasure to MeasureID, PlotID1, PlotID2, MeasureYear, remove duplicates
  ## then find repeat measures of MeasureYear, match back to MeasureID in both PSPplot and PSPmeasure.
  message(yellow("Filtering by at least ",  " measures per plot"))

  repeats <- PSPmeasure[, .(MeasureID, OrigPlotID1, MeasureYear)] %>%
    .[!duplicated(.)] %>%
    .[, .('repeatMeasures' = .N), by = .(OrigPlotID1)] %>%
    .[repeatMeasures >= minMeasures]
  setkey(repeats, OrigPlotID1)
  setkey(PSPmeasure, OrigPlotID1)
  PSPmeasure <- PSPmeasure[repeats]
  PSPplot <- PSPplot[MeasureID %in% PSPmeasure$MeasureID] ## ensures all plots have biomass/repeat measures

  message(yellow(paste0("There are "), nrow(repeats),
                 " PSPs with min. ", minMeasures, " repeat measures"))

  tempVariableNames <- unname(climateVariables)
  #data.table will assign the subset columns to the variable name, which is problematic if some are NULL
  PSPclimData <- PSPclimData[OrigPlotID1 %in% PSPmeasure$OrigPlotID1, .SD,
                             .SDcols = tempVariableNames, .(OrigPlotID1, Year)]
  PSPmeasure <- PSPmeasure[OrigPlotID1 %in% PSPclimData$OrigPlotID1,]
  PSPplot <- PSPplot[OrigPlotID1 %in% PSPmeasure$OrigPlotID1,]
  if (any(nrow(PSPclimData) == 0, nrow(PSPmeasure) == 0, nrow(PSPgis) == 0)) {
    stop('all existing PSP data has been filtered.Try adjusting parameters')
  }

  #make sure that you have a consistent set of plots and measurements here

  #Calculate mean of climate variables
  pSppChange <- lapply(unique(PSPplot$OrigPlotID1),
                       FUN = sumPeriod, m = PSPmeasure, p = PSPplot, dbh = minDBH_tag,
                       clim = PSPclimData, climVar = tempVariableNames)
  PSPmodelData <- rbindlist(pSppChange)

  #if c.m. has partial names, the empty names become "", with no names they are NULL
  anomalies <- climateVariables[!names(climateVariables) %in% c("")]
  if (length(anomalies) > 0) {
    #check if year is already subset - if not, subset to PSP period
    anomalyData <- PSPclimData[Year >= min(climateNormal) & Year <= max(climateNormal),
                               lapply(.SD, mean), .SDcol = anomalies, .(OrigPlotID1)]
    if (anyNA(anomalyData[, .SD, .SDcol = anomalies])) {
      stop("A problem occurred while calculating climate anomalies. Review climateNormal param?")
    }
    setnames(anomalyData, old = anomalies, new = names(anomalies))
    PSPmodelData <- anomalyData[PSPmodelData, on = c("OrigPlotID1")]

    #recalculate the anomaly(s) via subtraction
    for (i in 1:length(anomalies)) {
      #index because the name isn't preserved if you take the object itself
      temp <- anomalies[i]
      setnames(PSPmodelData, c(temp, names(temp)), c("var", "anom"))
      PSPmodelData[, anom := var - anom]
      newOrderCols <- names(PSPmodelData)[!names(PSPmodelData) %in% c("var", "anom") ]
      setcolorder(PSPmodelData, newOrderCols)
      setnames(PSPmodelData, c("var", "anom"), c(temp, names(temp)))
    }
  }


  ## Standardize by plotSize and change units from kg/ha to g/m2. = *1000 g/kg / 10000 m2/ha
  PSPmodelData <- PSPmodelData[, growth_gm2 := growth/plotSize/10] %>%
    .[, mortality_gm2 := mortality/plotSize/10] %>%
    .[, netBiomassChng_gm2 := netBiomassChng/plotSize/10]

  # Sum species-specific mortality, growth, and net biomass by plot and year
  # growth is set to 1 if it would be 0 (to avoid model error - anyway 0 growth is measurement error)
  PSPmodelSum <- PSPmodelData[, .("growth" = pmax(1, sum(growth_gm2)), "mortality" = sum(mortality_gm2),
                                  "netBiomass" = sum(netBiomassChng_gm2), biomass = sum(biomass)),
                              by = c("OrigPlotID1", "period", "Species")]

  PSPmodelData[, c("mortality_gm2", "growth_gm2", "netBiomassChng_gm2", "growth", "mortality") := NULL]
  PSPmodelData <- unique(PSPmodelData)
  subCols <- names(PSPmodelData)[!names(PSPmodelData) %in% c(names(PSPmodelSum))]
  joinCols <- setdiff(names(PSPmodelData), subCols)

  #join back to get the climate and other relevant information
  # is this true?
  PSPmodelMean <- unique(PSPmodelData[, .SD, .SDcols = c(subCols, joinCols)])
  PSPmodelMean[, N := .N, .(OrigPlotID1, period, Species)]
  if (nrow(PSPmodelMean[N > 1,]) > 0) {
    stop("an issue has occured with PSP data model building")
  }
  PSPmodelData <- PSPmodelSum[PSPmodelMean, on = joinCols]

  PSPmodelData <- unique(PSPplot[, .(OrigPlotID1, plotNumeric)])[PSPmodelData, on = c("OrigPlotID1")]
  PSPmodelData[, logGrowth := log(growth)]
  # PSPmodelData[, logMortality := log(mortality)] #don't log mortality as it is zero inflated

  setcolorder(PSPmodelData, c("OrigPlotID1", "plotNumeric", "plotSize", "year", "period", "periodLength",
                              "standAge", "logAge", "Species", "growth", "logGrowth",
                              "mortality", "biomass", "netBiomassChng"))

  #lastly subset by period length
  tooLong <- PSPmodelData[periodLength > maxInterval, .N, .(OrigPlotID1, year)]
  message("removing ", nrow(tooLong), " measurements for exceeding max interval period of ", maxInterval, " years")
  PSPmodelData <- PSPmodelData[periodLength <= maxInterval,]
  
  #calculate biomass as the sum of biomass by species within a plot,
  # and scale growth by biomass
  PSPmodelData[, standBiomass := sum(biomass), .(OrigPlotID1, period)]
  PSPmodelData[, growth_over_B := growth/biomass]
  PSPmodelData[, mortality_over_B := mortality/biomass]

  #TODO: spp should probably join with sppEquiv at some point - maybe here?

  PSPmodelData[, spp := Species]

  return(PSPmodelData)
}

gmcsModelBuild <- function(PSPmodelData, model) {
  assign("PSPmodelData", PSPmodelData, .GlobalEnv)
  ## this prevents cache envir arg from conflicting with eval envir
  gmcsModel <- eval(model, envir = environment())

  return(gmcsModel)
}

pspIntervals <- function(i, M, P, Clim, ClimVar, dbh) {

  #Calculate climate variables
  meanClim <- Clim[Year >= P$MeasureYear[i] & Clim$Year <= P$MeasureYear[i + 1],
                   lapply(.SD, mean), .SDcol = ClimVar, .(OrigPlotID1)]

  period <- paste0(P$MeasureYear[i], "-", P$MeasureYear[i + 1])
  m1 <- M[MeasureYear == P$MeasureYear[i]]
  m2 <- M[MeasureYear == P$MeasureYear[i + 1]]
  censusLength <- P$MeasureYear[i + 1] - P$MeasureYear[i]
  year <- ceiling(sum(P$MeasureYear[i] + P$MeasureYear[i + 1]) / 2)
  living1 <- m1[m1$TreeNumber %in% m2$TreeNumber]
  living2 <- m2[m2$TreeNumber %in% m1$TreeNumber]
  dead <- m1[!m1$TreeNumber %in% m2$TreeNumber]
  recruitment <- m2[!m2$TreeNumber %in% m1$TreeNumber]

  if (nrow(recruitment) > 0) {
    #assume that they were 1nth away from minDBH, where n = measurement interval over stand age
    #it should be the censusLength + baseSA,
    recruitment_extrapolated <- copy(recruitment)
    currentAge <- P$MeasureYear[i + 1] - P$baseYear[i + 1] + P$baseSA[i + 1]
    # increment <- (1 - censusLength/currentAge) this understimated DBH 
    # recruitment_extrapolated[, DBH := dbh * increment]
    #must use current age to ensure censusLength is always smaller
    #note: dbh in this equation is the minimum dbh threshold
    
    #new method - calculate BAI, take 15th percentile 
    # it should be low because it is clearly slower growing 
    BAIs <- copy(living1[, TreeNumber, DBH])
    setnames(BAIs, "DBH", "prior_DBH")
    BAIs <- BAIs[living2[, .(TreeNumber, DBH)], on = c("TreeNumber")]
    
    BAIs[, prior_basal_area_m2 := (pi * prior_DBH^2)/40000]
    BAIs[, basal_area_m2 := (pi * DBH^2)/40000]
    BAIs[, bai := (basal_area_m2 - prior_basal_area_m2)/censusLength]
    #technically we don't need census length because we just multiply it again...shut up
    BAI_15pct <- quantile(BAIs$bai, 0.15)
    recruitment_extrapolated[, bai := BAI_15pct] #purely for plots - its a constant
    recruitment_extrapolated[, basal_area_m2 := (pi * DBH ^2)/40000]
    recruitment_extrapolated[, prior_basal_area_m2 := basal_area_m2 - (bai * censusLength)]
    recruitment_extrapolated[, prior_DBH :=  200 * sqrt(prior_basal_area_m2/pi)]
    #take the floor of extrapolated DBh and minDBH
    recruitment_extrapolated[, prior_DBH := pmin(prior_DBH, dbh - 0.1)]
    #I don't know if the biomass equations allow 0 so for safety, floor is 0.1
    recruitment_extrapolated[, prior_DBH := pmax(prior_DBH, 0.1)]
      
    if (any(is.na(recruitment_extrapolated$Height))) {
      useHeight = FALSE
    } else {
      useHeight = TRUE
    }
    recruitment_extrapolated[, biomass := biomassCalculation(SpBiomassEq, prior_DBH, height = Height,
                                                         includeHeight = useHeight)$biomass, ]
    recruitment[, origBiomass := recruitment_extrapolated$biomass]

    recruitment <- recruitment[, .(newGrowth = sum(biomass - origBiomass)/unique(censusLength),
                           biomass = sum(origBiomass)), .(Species)] |>
      setkey(Species)
  } else {
    recruitment <- data.table(Species = character(0), newGrowth = numeric(0), biomass = numeric(0))
  }
    if (nrow(living1) != nrow(living2) | nrow(living1) + nrow(recruitment) <= 0) {
    warning("there is a problem in the PSP data with the plots: ", unique(m1$MeasureID), " ", unique(m2$MeasureID))
    return(NULL)
    ## `nrow(living1) == 0` will happen if tree numbers change between measurements
    }

  ## Find observed annual changes in mortality and growth
  living2$origBiomass <- living1$biomass
  ## growth cannot be negative, by definition
  living2[biomass < origBiomass, biomass := origBiomass]

  living <- living2[, .(newGrowth =  sum(biomass - origBiomass)/censusLength,
                        biomass = sum(origBiomass)), .(Species)] |>
    setkey(Species)


  #measure from census midpoint for new seedlings
  dead <- dead[, .(mortality = sum(biomass) / censusLength, biomass = sum(biomass)), .(Species)] |>
    setkey(Species)

  #Find unobserved growth and mortality.
  #Not necessary when summing by species, b/c we can't assign species for unobserved trees
  #Unobserved growth and mortality = ~1% of observed, so climate influences on this are trivial.
  #Leaving this in nonetheless, in case we change methods
  #Unobserved recruits U = N * R * M * L
  #N = # of trees with DBH between 10 and 15
  # N <- nrow(t2[DBH <= 15]) # where t2 = the second measurement
  # (I changed t from it's original 'm', to avoid confusion with metres squared and M mortality)
  # #R = number of recruits between two successive censuses (trees in t2 not in t1)/census length
  # R <- nrow(recruitment)/censusLength/N #I am not 100% sure if we divide by N or total stems in plot
  # #M = Mortality rate, n-trees with DBH 10 -15 that died between two census/interval length
  # M <- nrow(dead[DBH <= 15,])/censusLength/N
  # #L = census interval length
  # #Next calculate the median growth of the 10-15 DBH class, assume they grew to midpoint.
  # UnobservedR <- N * R * M * censusLength
  # UnobservedM <- UnobservedR * median(t2$biomass[t2$DBH <= 15])/censusLength/2
  # #assume unobserved trees died at midpoint. I think this overestimates growth and mortality
  # totalM <- UnobservedM + observedMortality
  # totalG <- UnobservedM + observedGrowth

  # changes <- rbind(recruitment, living)
  changes <- living

  changes$mortality <- 0
  dead$newGrowth <- 0
  changes <- rbind(changes, dead, recruitment, fill = TRUE) #recruitment will be zero here
  
  #fill NA as zero - regen has no mortality, dead has no growth
  changes[, c("newGrowth", "biomass", "mortality") := lapply(.SD, FUN = nafill, fill = 0),
          .SDcols = c("newGrowth", "biomass", "mortality")]

  #sum growth mortality and biomass by species
  changes <- changes[, .("growth" = sum(newGrowth), "mortality" = sum(mortality),
                         biomass = sum(biomass, na.rm = TRUE)),
                     .(Species)]
  changes[, netBiomassChng := growth - mortality]

  changes$period <- period
  changes$OrigPlotID1 <- P$OrigPlotID1[1]
  changes$year <- year
  changes$standAge <- P$baseSA[1] + P$MeasureYear[i + 1] - P$MeasureYear[1]
  changes$logAge <- log(changes$standAge)
  changes$plotSize <- P$PlotSize[1]
  changes$periodLength <- censusLength

  changes <- meanClim[changes, on = "OrigPlotID1"]
  setcolorder(changes, c("OrigPlotID1", "period", "Species", "growth", "mortality", "netBiomassChng",
                         "standAge", "logAge", "plotSize", "periodLength", ClimVar))
  return(changes)
}

sumPeriod <- function(x, m, p, clim, climVar, dbh) {
  # Tree No. is not unique between stands, which means the same plot can have duplicate trees.
  # sort by year. Calculate the changes in biomass, inc. unobserved growth and mortality
  # must match MeasureID between plot and measure data;
  m <- m[OrigPlotID1 == x,] #subset data by plot
  p <- p[MeasureID %in% m$MeasureID]
  clim <- clim[OrigPlotID1 %in% x,]
  p <- setkey(p, MeasureYear)
  m <- setkey(m, TreeNumber)
  periods <- nrow(p) - 1

  #For each interval
  pSums <- lapply(1:periods, FUN = pspIntervals,
                  M = m, P = p, Clim = clim, ClimVar = climVar, dbh = dbh)

  pSums <- rbindlist(pSums)
  return(pSums)
}

r2Fun <- function(x) {
  x[, resid := abs(obs - pred)]
  R2 <- 1 - sum(x$resid^2) / sum((x$obs - mean(x$obs))^2)
  return(R2)
}


.inputObjects <- function(sim) {
  cacheTags <- c(currentModule(sim), "function:.inputObjects")
  dPath <- asPath(inputPath(sim), 1)
  message(currentModule(sim), ": using dataPath '", dPath, "'.")

  if (!suppliedElsewhere("PSPmeasure_gmcs", sim) |
      !suppliedElsewhere("PSPplot_gmcs", sim) |
      !suppliedElsewhere("PSPgis_gmcs", sim)) {
    message("sourcing PSP data for gmcsDataPrep...")

    PSPdata <- Cache(getPSP,
                     PSPdataTypes = P(sim)$PSPdataTypes,
                     destinationPath = dPath,
                     forGMCS = TRUE,
                     userTags = c(cacheTags, P(sim)$PSPdataTypes, "getPSP"))

    sim$PSPmeasure_gmcs <- PSPdata$PSPmeasure
    sim$PSPplot_gmcs <- PSPdata$PSPplot
    sim$PSPgis_gmcs <- PSPdata$PSPgis
  }

  if (!suppliedElsewhere("studyArea", sim)) {
    message("studyArea not supplied. Using a random area in Alberta")
    sim$studyArea <- randomStudyArea(size = 1e6*50)
  }

  if (!suppliedElsewhere("PSPclimData", sim)) {
    sim$PSPclimData <- prepInputs(url = extractURL("PSPclimData"),
                                  targetFile = "PSPforClimateNA_BC_AB_SK_ON_QC_NB_NFI.csv",
                                  destinationPath = dPath,
                                  fun = "data.table::fread")
    sim$PSPclimData <- sim$PSPclimData[MAT != -9999] #missing plots get -9999 as variable
    #this must be done first as some data is "malformed" exiting ClimateNA
    setnames(sim$PSPclimData, old = c("id1"), new = c("OrigPlotID1"))
    if (!is.null(sim$PSPclimData$id2)) {
      sim$PSPclimData[, id2 := NULL]
    }
  }

  if (!suppliedElsewhere("sppEquivLong", sim)) {
    sim$sppEquivLong <- LandR::sppEquivalencies_CA
  }

  return(invisible(sim))
}
### add additional events as needed by copy/pasting from above
