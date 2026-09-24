arrow_writer_dataset <- function(x) {
  path <- tempfile(fileext = ".parquet")
  arrow::write_parquet(x, path)
  arrow::open_dataset(path)
}

with_small_arrow_writer_batches <- function(code) {
  old <- options(marcxmlr.writer_arrow_batch_size = 3L)
  on.exit(options(old), add = TRUE)
  force(code)
}

test_that("write_marcxml round trips an Arrow Dataset across batch boundaries", {
  skip_if_not_installed("arrow")

  x <- canonical_writer_fixture()
  dataset <- arrow_writer_dataset(x)
  out <- tempfile(fileext = ".xml")

  with_small_arrow_writer_batches({
    expect_no_warning(write_marcxml(dataset, out))
  })

  expect_identical(read_marcxml(out), x)
})

test_that("write_marcxml consumes a lazy Arrow query without materialising it", {
  skip_if_not_installed("arrow")
  skip_if_not_installed("dplyr")

  x <- canonical_writer_fixture()
  dataset <- arrow_writer_dataset(x)
  query <- dplyr::filter(dataset, record_id == 2L)
  out <- tempfile(fileext = ".xml")

  with_small_arrow_writer_batches({
    expect_warning(
      write_marcxml(query, out),
      class = "marcxmlr_canonical_warning"
    )
  })

  observed <- read_marcxml(out)
  expected <- x[x$record_id == 2L, , drop = FALSE]

  expect_identical(unique(observed$record_id), 1L)
  expect_equal(canonical_semantics(observed), canonical_semantics(expected))
})

test_that("Arrow writer splits only at complete-record boundaries", {
  skip_if_not_installed("arrow")

  x <- canonical_writer_fixture()
  third <- x[x$record_id == 2L, , drop = FALSE]
  third$record_id <- 3L
  x <- rbind(x, third)
  dataset <- arrow_writer_dataset(x)

  dir <- tempfile("marcxmlr-arrow-shards-")
  dir.create(dir)

  with_small_arrow_writer_batches({
    paths <- write_marcxml(
      dataset,
      file.path(dir, "catalogue.xml"),
      records_per_file = 2L
    )
  })

  expect_identical(
    basename(paths),
    c("catalogue-00001.xml", "catalogue-00002.xml")
  )
  expect_identical(length(unique(read_marcxml(paths[[1L]])$record_id)), 2L)
  expect_identical(length(unique(read_marcxml(paths[[2L]])$record_id)), 1L)
})

test_that("Arrow writer supports an empty canonical Dataset", {
  skip_if_not_installed("arrow")

  x <- canonical_writer_fixture()[0, , drop = FALSE]
  dataset <- arrow_writer_dataset(x)
  out <- tempfile(fileext = ".xml")

  with_small_arrow_writer_batches({
    expect_no_warning(write_marcxml(dataset, out))
  })

  doc <- xml2::read_xml(out)
  expect_identical(xml2::xml_name(xml2::xml_root(doc)), "collection")
  expect_length(xml2::xml_find_all(doc, "//*[local-name()='record']"), 0L)
})

test_that("Arrow writer rejects missing canonical columns before writing", {
  skip_if_not_installed("arrow")

  x <- canonical_writer_fixture()
  x$ind2 <- NULL
  dataset <- arrow_writer_dataset(x)
  out <- tempfile(fileext = ".xml")

  expect_error(
    write_marcxml(dataset, out),
    class = "marcxmlr_canonical_error"
  )
  expect_false(file.exists(out))
})

test_that("Arrow writer rejects non-contiguous record ordering", {
  skip_if_not_installed("arrow")

  x <- canonical_writer_fixture()
  x <- x[order(x$record_id, decreasing = TRUE), , drop = FALSE]
  dataset <- arrow_writer_dataset(x)
  out <- tempfile(fileext = ".xml")

  with_small_arrow_writer_batches({
    expect_error(
      write_marcxml(dataset, out),
      class = "marcxmlr_arrow_order_error"
    )
  })
  expect_false(file.exists(out))
})

test_that("Arrow writer keeps structural checks active when check is FALSE", {
  skip_if_not_installed("arrow")

  x <- canonical_writer_fixture()
  idx <- which(x$record_id == 1L & x$field_order == 2L)
  x$ind1[idx[[2L]]] <- "2"
  dataset <- arrow_writer_dataset(x)
  out <- tempfile(fileext = ".xml")

  with_small_arrow_writer_batches({
    expect_error(
      write_marcxml(dataset, out, check = FALSE),
      class = "marcxmlr_canonical_error"
    )
  })
  expect_false(file.exists(out))
})
