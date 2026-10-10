diagnostics_arrow_dataset <- function(x) {
  path <- tempfile(fileext = ".parquet")
  arrow::write_parquet(x, path)
  arrow::open_dataset(path)
}

with_small_diagnostic_batches <- function(code) {
  old <- options(marcxmlr.writer_arrow_batch_size = 3L)
  on.exit(options(old), add = TRUE)
  force(code)
}

test_that("diagnose_canonical accepts a clean Arrow Dataset", {
  skip_if_not_installed("arrow")

  x <- canonical_writer_fixture()
  dataset <- diagnostics_arrow_dataset(x)

  diagnostics <- with_small_diagnostic_batches({
    diagnose_canonical(dataset)
  })

  expect_s3_class(diagnostics, "tbl_df")
  expect_named(
    diagnostics,
    c(
      "severity", "code", "message",
      "record_id", "field_order", "subfield_order"
    )
  )
  expect_equal(nrow(diagnostics), 0L)
})

test_that("Arrow diagnostics preserve record-level checks across batch boundaries", {
  skip_if_not_installed("arrow")

  x <- canonical_writer_fixture()
  idx <- which(x$record_id == 1L & x$field_order == 2L)
  x$ind1[idx[[2L]]] <- "2"
  dataset <- diagnostics_arrow_dataset(x)
  expected <- diagnose_canonical(x)

  old <- options(marcxmlr.writer_arrow_batch_size = 1L)
  on.exit(options(old), add = TRUE)
  observed <- diagnose_canonical(dataset)

  expect_identical(observed, expected)
})

test_that("Arrow diagnostics match in-memory warning semantics", {
  skip_if_not_installed("arrow")

  x <- canonical_writer_fixture()
  x$subfield_order[x$field_type == "leader"] <- 99L
  x$subfield_occurrence[x$field_type == "leader"] <- 99L
  dataset <- diagnostics_arrow_dataset(x)

  expected <- diagnose_canonical(x)
  observed <- with_small_diagnostic_batches({
    diagnose_canonical(dataset)
  })

  expect_identical(observed, expected)
})

test_that("Arrow diagnostics report missing canonical columns instead of writing", {
  skip_if_not_installed("arrow")

  x <- canonical_writer_fixture()
  x$ind2 <- NULL
  dataset <- diagnostics_arrow_dataset(x)

  diagnostics <- diagnose_canonical(dataset)

  expect_true("missing_columns" %in% diagnostics$code)
  expect_true(any(diagnostics$severity == "error"))
})

test_that("Arrow diagnostics report unsupported physical record ordering", {
  skip_if_not_installed("arrow")

  x <- canonical_writer_fixture()
  x <- x[order(x$record_id, decreasing = TRUE), , drop = FALSE]
  dataset <- diagnostics_arrow_dataset(x)

  diagnostics <- with_small_diagnostic_batches({
    diagnose_canonical(dataset)
  })

  expect_identical(diagnostics$code, "arrow_record_order")
  expect_identical(diagnostics$severity, "error")
})

test_that("Arrow diagnostics preserve record_id continuity warnings", {
  skip_if_not_installed("arrow")
  skip_if_not_installed("dplyr")

  x <- canonical_writer_fixture()
  dataset <- diagnostics_arrow_dataset(x)
  query <- dplyr::filter(dataset, record_id == 2L)

  diagnostics <- with_small_diagnostic_batches({
    diagnose_canonical(query)
  })

  expect_false(any(diagnostics$severity == "error"))
  expect_true("record_id_will_renumber" %in% diagnostics$code)
})

test_that("Arrow diagnostics suppress warnings when structural errors exist", {
  skip_if_not_installed("arrow")

  x <- canonical_writer_fixture()
  x$field_order[x$record_id == 1L & x$field_order == 3L] <- 4L
  x$tag[x$record_id == 2L & x$field_type == "leader"] <- "BAD"
  dataset <- diagnostics_arrow_dataset(x)

  diagnostics <- with_small_diagnostic_batches({
    diagnose_canonical(dataset)
  })

  expect_true("invalid_leader_tag" %in% diagnostics$code)
  expect_true(all(diagnostics$severity == "error"))
})

test_that("diagnose_canonical accepts an empty Arrow Dataset", {
  skip_if_not_installed("arrow")

  x <- canonical_writer_fixture()[0, , drop = FALSE]
  dataset <- diagnostics_arrow_dataset(x)

  diagnostics <- diagnose_canonical(dataset)

  expect_equal(nrow(diagnostics), 0L)
})
