## gmcsDataPrep.R, read from the source (SpaDES.core is not needed): where its figures go (issue #3),
## and its metadata against the code (issue #1).

module_file <- function() testthat::test_path("..", "..", "gmcsDataPrep.R")

module_code <- function() {
  paste(deparse(parse(module_file(), keep.source = FALSE)), collapse = "\n")
}

## The defineModule() metadata list, as a call.
module_metadata <- function() {
  exprs <- as.list(parse(module_file(), keep.source = FALSE))
  dm <- Find(function(e) is.call(e) && identical(e[[1L]], as.name("defineModule")), exprs)
  dm[[3L]]
}

## The object names in the expectsInput() or createsOutput() calls of a metadata section.
declared <- function(section) {
  calls <- Filter(is.call, as.list(module_metadata()[[section]])[-1L])
  vapply(
    calls,
    function(cl) {
      args <- as.list(cl)[-1L]
      if (!is.null(args$objectName)) args$objectName else args[[1L]]
    },
    ""
  )
}

## The names x in every sim$x of the module's code.
sim_objects <- function() {
  pd <- utils::getParseData(parse(module_file(), keep.source = TRUE))
  pd <- pd[pd$terminal, ]
  pd <- pd[order(pd$line1, pd$col1), ]
  i <- which(pd$token == "SYMBOL" & pd$text == "sim")
  i <- i[i + 2L <= nrow(pd)]
  hit <- pd$token[i + 1L] == "'$'" & pd$token[i + 2L] == "SYMBOL"
  sort(unique(pd$text[i[hit] + 2L]))
}

test_that("figures go under figurePath(sim), never a figures folder built from outputPath(sim)", {
  skip_on_cran()
  code <- module_code()
  expect_false(grepl('outputPath(sim), "figures"', code, fixed = TRUE))
  expect_true(grepl("figurePath(sim)", code, fixed = TRUE))
})

test_that("every sim$ object the module uses is declared as an input or an output", {
  skip_on_cran()
  undeclared <- setdiff(sim_objects(), c(declared("inputObjects"), declared("outputObjects")))
  expect_identical(undeclared, character())
})

test_that("no object is declared twice", {
  skip_on_cran()
  expect_identical(anyDuplicated(declared("inputObjects")), 0L)
  expect_identical(anyDuplicated(declared("outputObjects")), 0L)
})

test_that("the files named in `documentation` exist", {
  skip_on_cran()
  docs <- unlist(eval(module_metadata()$documentation, baseenv()))
  expect_true(all(file.exists(testthat::test_path("..", "..", docs))))
})

test_that("caret is pinned to a commit: its xgboost 3.x fix is not in a version number", {
  skip_on_cran()
  pkgs <- unlist(eval(module_metadata()$reqdPkgs, baseenv()))
  expect_match(grep("caret", pkgs, value = TRUE), "^topepo/caret@[0-9a-f]{40}$")
})

test_that("no package is declared that the module's code never uses", {
  skip_on_cran()
  pkgs <- unlist(eval(module_metadata()$reqdPkgs, baseenv()))
  expect_false(any(grepl("^(lightgbm|pROC)\\b", pkgs)))
})
