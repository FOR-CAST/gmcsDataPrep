## R/xgboost_caret_flow.R: runXGBOOST() and .tunexgboost(), on made-up data. Run through
## tests/run-tests.R, which sources R/ and leaves caret and lattice unattached.

## Made-up plot data: three predictors and a growth response that depends on them, `n` rows; with
## `years`, a `year` column cycles through them (runXGBOOST() then cross-validates in time order).
fake_psp <- function(n = 120L, years = NULL) {
  withr::local_seed(1L)
  d <- data.table::data.table(
    MAT = stats::runif(n, -5, 5),
    CMI = stats::runif(n, -20, 40),
    B = stats::runif(n, 0, 300)
  )
  d[, logGrowth := 0.3 * MAT + 0.02 * CMI - 0.001 * B + stats::rnorm(n, sd = 0.2)]
  if (length(years)) {
    d[, year := rep_len(years, n)]
  }
  d[]
}

## Replace .tunexgboost() with fixed, small settings for one test: its full grid takes minutes.
local_fixed_tuning <- function(frame = parent.frame()) {
  old <- .tunexgboost
  assign(
    ".tunexgboost",
    function(...) {
      data.frame(
        nrounds = 20,
        max_depth = 2,
        eta = 0.3,
        gamma = 0,
        colsample_bytree = 1,
        min_child_weight = 1,
        subsample = 1
      )
    },
    envir = globalenv()
  )
  withr::defer(assign(".tunexgboost", old, envir = globalenv()), envir = frame)
}

expect_folds <- function(out, nFolds) {
  expect_length(out, nFolds)
  for (fold in out) {
    expect_named(fold, c("valData", "mod", "shap_values", "shap_long"))
    expect_true(all(c("obs", "pred", "resid") %in% names(fold$valData)))
    expect_equal(fold$valData$resid, fold$valData$pred - fold$valData$obs)
  }
}

test_that("runXGBOOST(): k-fold cross-validation, one model per fold", {
  skip_on_cran()
  local_fixed_tuning()
  out <- runXGBOOST(fake_psp(), nFolds = 3, colnamesResp = "logGrowth", eval_metric = "rmse")
  expect_folds(out, 3L)
  ## the folds split the rows: each is tested once
  expect_equal(sum(vapply(out, function(f) nrow(f$valData), integer(1))), 120L)
})

test_that("runXGBOOST(): a year column gives time-ordered folds and is not a predictor", {
  skip_on_cran()
  local_fixed_tuning()
  ## named in any case: the column is found ignoring case
  dat <- data.table::setnames(fake_psp(years = 2001:2012), "year", "Year")
  out <- runXGBOOST(dat, nFolds = 3, colnamesResp = "logGrowth", eval_metric = "rmse")
  expect_folds(out, 3L)
  for (fold in out) {
    expect_setequal(setdiff(names(fold$valData), c("obs", "pred", "resid")), c("MAT", "CMI", "B"))
  }
})

test_that("runXGBOOST(): leaves the random number generator as it found it, used or not", {
  skip_on_cran()
  local_fixed_tuning()
  dat <- fake_psp()
  old <- if (exists(".Random.seed", envir = globalenv())) get(".Random.seed", envir = globalenv())
  withr::defer(if (is.null(old)) suppressWarnings(rm(".Random.seed", envir = globalenv())) else
    assign(".Random.seed", old, envir = globalenv()))
  ## not yet used: no .Random.seed before, none after
  suppressWarnings(rm(".Random.seed", envir = globalenv()))
  runXGBOOST(dat, nFolds = 3, colnamesResp = "logGrowth", eval_metric = "rmse")
  expect_false(exists(".Random.seed", envir = globalenv()))
  ## used: the same state after as before
  set.seed(42L)
  before <- get(".Random.seed", envir = globalenv())
  runXGBOOST(dat, nFolds = 3, colnamesResp = "logGrowth", eval_metric = "rmse")
  expect_identical(get(".Random.seed", envir = globalenv()), before)
})

test_that(".tunexgboost(): tunes in three steps and saves the three tuning plots", {
  skip_on_cran()
  fig <- withr::local_tempdir()
  dat <- fake_psp(60L)
  best <- .tunexgboost(NULL, dat, "logGrowth", figDir = fig, cachePath = NULL)
  expect_s3_class(best, "data.frame")
  expect_equal(nrow(best), 1L)
  expect_true(all(
    c("nrounds", "max_depth", "eta", "gamma", "colsample_bytree", "min_child_weight") %in%
      names(best)
  ))
  expect_setequal(
    list.files(fig),
    paste0("logGrowth_tuning_", c("learningRate", "all", "nrounds"), ".png")
  )
})

## The thread count. parallelly::availableCores() follows `mc.cores` (tests/run-tests.R sets it to
## the test cores), and its "connections" constraint keeps the count within R's free connections,
## which a machine with more than ~125 cores would otherwise exceed.

test_that("the test runner limits the cores parallelly reports to the test cores", {
  expect_lte(parallelly::availableCores(), 4L)
})

test_that(".resolveThreads(): a request above the available cores is capped, with a message", {
  withr::local_options(mc.cores = 2L)
  expect_message(n <- .resolveThreads(64L), "64", fixed = TRUE)
  expect_identical(n, 2L)
})

test_that(".resolveThreads(): a request within the available cores is kept", {
  withr::local_options(mc.cores = 2L)
  expect_identical(.resolveThreads(1L), 1L)
})

test_that(".defaultThreads() and .resolveThreads() count cores within R's free connections", {
  asked <- list()
  local_mocked_bindings(
    availableCores = function(constraints = NULL, ...) {
      asked[[length(asked) + 1L]] <<- constraints
      8L
    },
    .package = "parallelly"
  )
  expect_lte(.defaultThreads(), 8L)
  expect_identical(suppressMessages(.resolveThreads(16L)), 8L)
  expect_identical(unique(unlist(asked)), "connections")
  expect_length(asked, 2L)
})
