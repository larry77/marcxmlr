test_that("buffered single pass matches C1 and full parser across batches", {
  file <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  full <- read_marcxml(file)
  keep_650 <- function(x, record_ids) {
    record_ids %in% x$record_id[x$tag == "650" & x$subfield_code == "a"]
  }
  for (size in c(1L, 2L, 10L)) {
    c2 <- .prototype_read_marcxml_buffered(
      file, "650", keep_650, screen_batch_records = size
    )
    c1 <- .prototype_read_marcxml_filtered(
      file, "650", keep_650, screen_batch_records = size
    )
    expect_identical(c2, c1)
    expect_identical(c2, full[full$record_id == 1L, , drop = FALSE])
  }
})

test_that("buffered selection handles none, all, absence and zero max", {
  file <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  full <- read_marcxml(file)
  all <- .prototype_read_marcxml_buffered(
    file, "001", function(x, ids) rep(TRUE, length(ids)),
    screen_batch_records = 1L
  )
  expect_identical(all, full)
  empty <- .prototype_read_marcxml_buffered(
    file, "650", function(x, ids) rep(FALSE, length(ids))
  )
  expect_identical(empty, .empty_marcxml())
  absent <- .prototype_read_marcxml_buffered(
    file, "650", function(x, ids) !(ids %in% unique(x$record_id)),
    screen_batch_records = 1L
  )
  expect_identical(absent, full[full$record_id == 2L, , drop = FALSE])
  zero <- .prototype_read_marcxml_buffered(
    file, "650", function(x, ids) rep(TRUE, length(ids)), n_max = 0
  )
  expect_identical(zero, .empty_marcxml())
})

test_that("buffered selected records retain field instances and repeated subfields", {
  file <- system.file("extdata", "gpo-cgp-part00-sample.xml", package = "marcxmlr")
  skip_if(!nzchar(file))
  matches <- function(x, ids) {
    ids %in% x$record_id[x$tag == "650" & x$subfield_code == "a" &
                         x$value == "Flood insurance"]
  }
  a <- .prototype_read_marcxml_filtered(
    file, "650", matches, screen_batch_records = 23L
  )
  b <- .prototype_read_marcxml_buffered(
    file, "650", matches, screen_batch_records = 23L
  )
  expect_identical(b, a)
  expect_identical(length(unique(b$record_id)), 28L)
  expect_identical(nrow(b), 1320L)
})

test_that("buffered selection supports standalone MARCXML", {
  file <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  rec <- xml2::xml_find_first(xml2::read_xml(file), "//*[local-name()='record']")
  stand <- tempfile(fileext = ".xml")
  on.exit(unlink(stand), add = TRUE)
  xml <- sub("<marc:record",
             '<marc:record xmlns:marc="http://www.loc.gov/MARC21/slim"',
             as.character(rec), fixed = TRUE)
  writeLines(xml, stand, useBytes = TRUE)
  ans <- .prototype_read_marcxml_buffered(
    stand, "650", function(x, ids) rep(TRUE, length(ids))
  )
  expect_identical(ans, read_marcxml(stand))
})

test_that("buffered filter rejects invalid callbacks and retains package scope", {
  file <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  expect_error(.prototype_read_marcxml_buffered(
    file, "650", function(x, ids) TRUE), "one element per input record")
  expect_error(.prototype_read_marcxml_buffered(
    file, "650", function(x, ids) rep(NA, length(ids))),
    "non-missing logical")
  expect_error(.prototype_read_marcxml_buffered(
    file, "notatag", function(x, ids) rep(TRUE, length(ids))),
    "MARC field tags")
})

test_that("buffered Parquet result matches two-pass filtered rows", {
  skip_if_not_installed("arrow")
  skip_if_not_installed("dplyr")
  file <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  dest <- tempfile("buffered-test-")
  on.exit(unlink(dest, recursive = TRUE), add = TRUE)
  predicate <- function(x, ids) ids %in% unique(x$record_id)
  meta <- .prototype_marcxml_to_parquet_buffered(
    file, dest, "650", predicate, screen_batch_records = 1L
  )
  expect_identical(meta$records, 1L)
  actual <- dplyr::collect(arrow::open_dataset(dest))
  expected <- read_marcxml(file, n_max = 1L)
  expect_equal(actual[names(expected)], expected, ignore_attr = TRUE)
})
