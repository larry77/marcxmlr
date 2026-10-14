test_that("experimental screening preserves complete selected records and source IDs", {
  file <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  full <- read_marcxml(file)

  screened <- .prototype_read_marcxml_filtered(
    file, filter_tags = "100", screen_batch_records = 1L,
    record_filter = function(x, record_ids) {
      record_ids %in% x$record_id[x$subfield_code == "a"]
    }
  )
  expect_identical(screened, full[full$record_id == 2L, , drop = FALSE])
  expect_true(all(screened$record_id == 2L))
  expect_true(any(screened$tag == "245"))
  expect_true(any(screened$tag == "500"))
})

test_that("screening supports record-level absence tests and empty screening tables", {
  file <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  full <- read_marcxml(file)
  result <- .prototype_read_marcxml_filtered(
    file, "650", screen_batch_records = 2L,
    record_filter = function(x, record_ids) {
      !(record_ids %in% unique(x$record_id))
    }
  )
  expect_identical(result, full[full$record_id == 2L, , drop = FALSE])

  nothing <- .prototype_read_marcxml_filtered(
    file, "001", record_filter = function(x, record_ids) {
      rep(FALSE, length(record_ids))
    }
  )
  expect_identical(nothing, .empty_marcxml())
})

test_that("screening exposes field-instance coordinates and permits dplyr", {
  skip_if_not_installed("dplyr")
  file <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  result <- .prototype_read_marcxml_filtered(
    file, "650", screen_batch_records = 1L,
    record_filter = function(x, record_ids) {
      matches <- x |>
        dplyr::filter(subfield_code == "a", value == "Metadata") |>
        dplyr::pull(record_id)
      record_ids %in% matches
    }
  )
  expect_setequal(unique(result$record_id), 1L)
  expect_identical(result, read_marcxml(file, n_max = 1))
})

test_that("screening validates callback shape", {
  file <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  expect_error(
    .prototype_read_marcxml_filtered(file, "650", function(x, record_ids) TRUE),
    "one element per input record"
  )
  expect_error(
    .prototype_read_marcxml_filtered(file, "650",
      function(x, record_ids) rep(NA, length(record_ids))),
    "non-missing logical"
  )
  expect_error(
    .prototype_read_marcxml_filtered(file, "bad tag",
      function(x, record_ids) rep(TRUE, length(record_ids))),
    "MARC field tags"
  )
})

test_that("screening handles zero max and standalone records", {
  file <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  result <- .prototype_read_marcxml_filtered(
    file, "650", function(x, record_ids) rep(TRUE, length(record_ids)), n_max = 0
  )
  expect_identical(result, .empty_marcxml())
  standalone <- tempfile(fileext = ".xml")
  on.exit(unlink(standalone), add = TRUE)
  # The standalone fixture is derived from the first record of the collection.
  doc <- xml2::read_xml(file)
  rec <- xml2::xml_find_first(doc, "//*[local-name()='record']")
  # Writing a nested XML node directly omits the namespace declaration
  # inherited from <collection>. Make the standalone fixture self-contained.
  record_xml <- sub(
    "<marc:record",
    '<marc:record xmlns:marc="http://www.loc.gov/MARC21/slim"',
    as.character(rec),
    fixed = TRUE
  )
  writeLines(record_xml, standalone, useBytes = TRUE)
  result <- .prototype_read_marcxml_filtered(
    standalone, "650", function(x, record_ids) rep(TRUE, length(record_ids))
  )
  expect_identical(result, read_marcxml(standalone))
})

test_that("experimental Parquet screening writes only complete records", {
  skip_if_not_installed("arrow")
  skip_if_not_installed("dplyr")
  file <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  out <- tempfile("filtered-dataset-")
  on.exit(unlink(out, recursive = TRUE), add = TRUE)
  info <- .prototype_marcxml_to_parquet_filtered(
    file, out, filter_tags = "650", screen_batch_records = 1L,
    record_filter = function(x, record_ids) record_ids %in% unique(x$record_id)
  )
  expect_identical(info$records, 1L)
  result <- dplyr::collect(arrow::open_dataset(out))
  expected <- read_marcxml(file, n_max = 1)
  expect_equal(result[names(expected)], expected, ignore_attr = TRUE)
})
