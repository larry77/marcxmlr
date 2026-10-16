# Regression tests for the installed/public MARC-aware record query interface.
# This file belongs in tests/testthat/test-marc-query-public.R.

sample_canonical <- function() {
  tibble::tibble(
    record_id           = c(1L, 1L, 1L, 2L, 2L, 2L, 3L, 3L),
    field_type          = c("controlfield", "datafield", "datafield",
                            "controlfield", "datafield", "datafield",
                            "controlfield", "datafield"),
    tag                 = c("001", "650", "856", "001", "650", "999", "001", "856"),
    subfield_code       = c(NA_character_, "a", "u", NA_character_, "a", "a",
                            NA_character_, "u"),
    value               = c("id1", "Economics", "https://europa.eu/1",
                            "id2", "Economics", "private", "id3", "https://example.org/3"),
    field_order         = c(1L, 2L, 3L, 1L, 2L, 3L, 1L, 2L),
    field_occurrence    = rep(1L, 8),
    ind1                = c(NA_character_, "0", "4", NA_character_, "0", " ",
                            NA_character_, "4"),
    ind2                = c(NA_character_, "0", "0", NA_character_, "0", " ",
                            NA_character_, "0"),
    subfield_order      = c(NA_integer_, 1L, 1L, NA_integer_, 1L, 1L,
                            NA_integer_, 1L),
    subfield_occurrence = c(NA_integer_, 1L, 1L, NA_integer_, 1L, 1L,
                            NA_integer_, 1L)
  )
}

sorted_canonical <- function(x) {
  x <- as.data.frame(x)
  x <- x[order(x$record_id, x$field_order, na.last = TRUE), , drop = FALSE]
  rownames(x) <- NULL
  x
}

testthat::test_that("public MARC query returns complete records for compound predicates", {
  x <- sample_canonical()
  query <- marc_has("650", subfield = "a", equals = "Economics") &
    marc_has("856", subfield = "u", contains = "europa.eu") &
    !marc_has("999")

  actual <- marc_filter_records(x, query)
  expected <- x[x$record_id == 1L, , drop = FALSE]
  testthat::expect_equal(sorted_canonical(actual), sorted_canonical(expected))
  testthat::expect_identical(names(actual), names(x))
  testthat::expect_equal(nrow(marc_filter_records(x, !marc_has("650"))), 2L)
  testthat::expect_equal(nrow(marc_filter_records(x, marc_has("777"))), 0L)
})

testthat::test_that("public MARC query has the same result on an Arrow Dataset", {
  testthat::skip_if_not_installed("arrow")
  x <- sample_canonical()
  path <- tempfile(fileext = ".parquet")
  on.exit(unlink(path), add = TRUE)
  arrow::write_parquet(x, path)
  ds <- arrow::open_dataset(path)

  query <- (marc_has("650", subfield = "a", contains = "Econ") &
              marc_has("856", subfield = "u")) &
    !marc_has("999")
  actual <- dplyr::collect(marc_filter_records(ds, query))
  expected <- marc_filter_records(x, query)
  testthat::expect_equal(sorted_canonical(actual), sorted_canonical(expected))
})
