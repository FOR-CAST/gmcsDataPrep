## gmcsDataPrep.R: the module's figures go under figurePath(sim), the folder SpaDES.core gives each
## module, not one built from outputPath(sim) (issue #3). Read from the source; SpaDES.core is not
## needed.

module_code <- function() {
  exprs <- parse(testthat::test_path("..", "..", "gmcsDataPrep.R"), keep.source = FALSE)
  paste(deparse(exprs), collapse = "\n")
}

test_that("figures go under figurePath(sim), never a figures folder built from outputPath(sim)", {
  skip_on_cran()
  code <- module_code()
  expect_false(grepl('outputPath(sim), "figures"', code, fixed = TRUE))
  expect_true(grepl("figurePath(sim)", code, fixed = TRUE))
})
