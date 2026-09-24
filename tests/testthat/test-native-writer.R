test_that("native writer matches the R reference semantics", {
  x <- canonical_writer_fixture()
  record_ids <- sort(unique(as.integer(x$record_id)))
  reference_file <- tempfile(fileext = ".xml")
  native_file <- tempfile(fileext = ".xml")
  on.exit(unlink(c(reference_file, native_file), force = TRUE), add = TRUE)

  .writer_write_collection_reference(
    x,
    record_ids = record_ids,
    file = reference_file,
    pretty = TRUE
  )
  .writer_write_collection_native(
    x,
    record_ids = record_ids,
    file = native_file,
    pretty = TRUE
  )

  reference <- read_marcxml(reference_file)
  native <- read_marcxml(native_file)

  expect_identical(native, reference)
  expect_identical(native, x)
})

test_that("native writer obeys canonical coordinates rather than row order", {
  x <- canonical_writer_fixture()
  shuffled <- x[rev(seq_len(nrow(x))), , drop = FALSE]
  record_ids <- sort(unique(as.integer(shuffled$record_id)))
  reference_file <- tempfile(fileext = ".xml")
  native_file <- tempfile(fileext = ".xml")
  on.exit(unlink(c(reference_file, native_file), force = TRUE), add = TRUE)

  .writer_write_collection_reference(
    shuffled,
    record_ids = record_ids,
    file = reference_file,
    pretty = FALSE
  )
  .writer_write_collection_native(
    shuffled,
    record_ids = record_ids,
    file = native_file,
    pretty = FALSE
  )

  expect_identical(
    read_marcxml(native_file),
    read_marcxml(reference_file)
  )
})

test_that("native writer handles empty collections", {
  x <- canonical_writer_fixture()[0, , drop = FALSE]
  reference_file <- tempfile(fileext = ".xml")
  native_file <- tempfile(fileext = ".xml")
  on.exit(unlink(c(reference_file, native_file), force = TRUE), add = TRUE)

  .writer_write_collection_reference(
    x,
    record_ids = integer(),
    file = reference_file,
    pretty = TRUE
  )
  .writer_write_collection_native(
    x,
    record_ids = integer(),
    file = native_file,
    pretty = TRUE
  )

  expect_identical(
    read_marcxml(native_file),
    read_marcxml(reference_file)
  )
})

test_that("native writer preserves record subsetting semantics", {
  x <- canonical_writer_fixture()
  selected <- x[x$record_id == 2L, , drop = FALSE]
  native_file <- tempfile(fileext = ".xml")
  on.exit(unlink(native_file, force = TRUE), add = TRUE)

  .writer_write_collection_native(
    selected,
    record_ids = 2L,
    file = native_file,
    pretty = TRUE
  )

  reread <- read_marcxml(native_file)

  expect_equal(unique(reread$record_id), 1L)
  expect_identical(
    canonical_semantics(reread),
    canonical_semantics(selected)
  )
})
