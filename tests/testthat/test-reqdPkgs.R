## gmcsDataPrep.R's metadata: every package the module's code calls with `pkg::` is declared in
## reqdPkgs, so simInit() installs and loads it. Read from the source; SpaDES.core is not needed.

## The module's declared packages, by name (no owner/, @ref or version).
reqd_pkgs <- function(file = testthat::test_path("..", "..", "gmcsDataPrep.R")) {
  exprs <- as.list(parse(file, keep.source = FALSE))
  dm <- Find(function(e) is.call(e) && identical(e[[1L]], as.name("defineModule")), exprs)
  pkgs <- unlist(eval(dm[[3L]]$reqdPkgs, baseenv()))
  basename(sub("@.*$", "", sub("\\s*\\(.*$", "", pkgs)))
}

## The packages named in `pkg::fun` calls in the module's code (comments and strings excluded).
qualified_pkgs <- function(files) {
  unique(unlist(lapply(files, function(f) {
    pd <- utils::getParseData(parse(f, keep.source = TRUE))
    pd$text[pd$token == "SYMBOL_PACKAGE"]
  })))
}

test_that("every package called with pkg:: is declared in reqdPkgs", {
  skip_on_cran()
  root <- testthat::test_path("..", "..")
  files <- c(
    file.path(root, "gmcsDataPrep.R"),
    list.files(file.path(root, "R"), "[.]R$", full.names = TRUE)
  )
  base <- c("base", "graphics", "grDevices", "methods", "parallel", "stats", "tools", "utils")
  expect_identical(setdiff(qualified_pkgs(files), c(reqd_pkgs(), base)), character())
})
