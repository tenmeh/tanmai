# pkgdown refuses to build a site that leaves a documented topic out of the
# reference index, which is the right call - it is exactly how a new function
# silently fails to appear in the documentation.
#
# The cost is that adding one exported function means touching four places: the
# roxygen tag, NAMESPACE, _pkgdown.yml, and any example that calls it. Missing
# the third has broken CI twice, each time several minutes after the push, so
# it is checked here instead - where `devtools::test()` finds it before anyone
# else does.
#
# This replicates pkgdown's own check_missing_topics() rather than calling
# pkgdown, which needs pandoc.

test_that("every documented topic appears in the pkgdown reference index", {
  # _pkgdown.yml is .Rbuildignore'd, so it is absent when the tests run from a
  # built package. Nothing to check there - CI's pkgdown job covers that case.
  yml_path <- testthat::test_path("..", "..", "_pkgdown.yml")
  man_dir <- testthat::test_path("..", "..", "man")
  skip_if_not(file.exists(yml_path) && dir.exists(man_dir), "not running from the source tree")

  rd <- list.files(man_dir, pattern = "\\.Rd$", full.names = TRUE)
  internal <- vapply(rd, function(f) {
    any(grepl("\\\\keyword\\{internal\\}", readLines(f, warn = FALSE)))
  }, logical(1))
  topics <- sub("\\.Rd$", "", basename(rd[!internal]))

  yml <- readLines(yml_path, warn = FALSE)
  entries <- trimws(sub("^\\s*-\\s*", "", yml[grepl("^\\s*-\\s+\\S", yml)]))

  # An index may match topics by pattern as well as by name, and those cover
  # real topics just as well as an explicit entry does.
  patterns <- grep("^starts_with\\(", entries, value = TRUE)
  prefixes <- sub('^starts_with\\("([^"]*)"\\).*$', "\\1", patterns)
  covered_by_pattern <- function(topic) any(startsWith(topic, prefixes))

  missing <- Filter(
    function(t) !(t %in% entries) && !covered_by_pattern(t),
    topics
  )

  expect_equal(
    missing, character(0),
    info = paste0(
      "Add these to _pkgdown.yml, or mark them @keywords internal: ",
      paste(missing, collapse = ", ")
    )
  )
})
