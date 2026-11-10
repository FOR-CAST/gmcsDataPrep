## Run the module's unit tests, from the module root: Rscript tests/run-tests.R [file filter]
## The tests call the helpers in R/ directly, so this sources them and attaches the packages behind
## their unqualified calls, as simInit() attaches the module's reqdPkgs. caret and lattice are left
## unattached on purpose: the helpers must call them with `pkg::`. Caching is off, as in a pipeline
## run. Every test is skip_on_cran(), so NOT_CRAN is set here. Used by
## .github/workflows/test-module.yaml.
## Tests use at most 2 cores, as CRAN asks; TEST_CORES raises that, to 4 at most, for a longer run.
## xgboost otherwise takes every core (caret's xgbTree tuning never sets nthread). R starts OpenMP
## and BLAS before this script runs, so the limits must be in the environment R starts with: without
## them, the script runs itself again in a new R process that has them.
asked <- suppressWarnings(as.integer(Sys.getenv("TEST_CORES")))
cores <- if (is.na(asked)) 2L else min(4L, max(1L, asked))
limit <- suppressWarnings(as.integer(Sys.getenv("OMP_THREAD_LIMIT")))
if (is.na(limit) || limit > cores) {
  status <- system2(
    file.path(R.home("bin"), "R"),
    shQuote(commandArgs(trailingOnly = FALSE)[-1L]),
    env = paste0(
      c("OMP_THREAD_LIMIT=", "OMP_NUM_THREADS=", "OPENBLAS_NUM_THREADS=", "MKL_NUM_THREADS="),
      cores
    )
  )
  quit(save = "no", status = status)
}
Sys.setenv(NOT_CRAN = "true")
options(reproducible.useCache = FALSE)
suppressPackageStartupMessages({
  library(testthat)
  library(crayon)
  library(data.table)
  library(purrr)
  library(reproducible)
  library(SHAPforxgboost)
  library(xgboost)
})
data.table::setDTthreads(cores)
## the module's thread count comes from parallelly::availableCores(), which follows mc.cores
options(mc.cores = cores)
for (f in list.files("R", "[.]R$", full.names = TRUE)) {
  source(f)
}
args <- commandArgs(trailingOnly = TRUE)
testthat::test_dir(
  file.path("tests", "testthat"),
  filter = if (length(args)) args[[1L]] else NULL,
  reporter = "summary",
  stop_on_failure = TRUE
)
