test_that("gzip MARCXML output round trips through the existing reader", {
  source_xml <- system.file(
    "extdata", "example-marcxml.xml",
    package = "marcxmlr"
  )
  x <- read_marcxml(source_xml)

  out <- tempfile(fileext = ".xml.gz")
  write_marcxml(x, out)

  expect_identical(
    as.integer(readBin(out, "raw", n = 2L)),
    c(31L, 139L)
  )
  expect_identical(read_marcxml(out), x)
})

test_that("gzip compression level is validated", {
  source_xml <- system.file(
    "extdata", "example-marcxml.xml",
    package = "marcxmlr"
  )
  x <- read_marcxml(source_xml)

  expect_error(
    write_marcxml(x, tempfile(fileext = ".xml.gz"), compression_level = 0L),
    class = "marcxmlr_argument_error"
  )
  expect_error(
    write_marcxml(x, tempfile(fileext = ".xml.gz"), compression_level = 10L),
    class = "marcxmlr_argument_error"
  )
})

test_that("gzip shard names preserve xml.gz", {
  source_xml <- system.file(
    "extdata", "example-marcxml.xml",
    package = "marcxmlr"
  )
  x <- read_marcxml(source_xml)

  dir <- tempfile("marcxmlr-gzip-shards-")
  dir.create(dir)
  on.exit(unlink(dir, recursive = TRUE), add = TRUE)

  paths <- write_marcxml(
    x,
    file.path(dir, "catalogue.xml.gz"),
    records_per_file = 1L
  )

  expect_true(all(grepl("-[0-9]{5}\\.xml\\.gz$", paths)))
  expect_true(all(file.exists(paths)))
})

test_that("lazy Arrow gzip output round trips", {
  skip_if_not_installed("arrow")

  source_xml <- system.file(
    "extdata", "example-marcxml.xml",
    package = "marcxmlr"
  )
  x <- read_marcxml(source_xml)

  dataset_dir <- tempfile("marcxmlr-gzip-arrow-")
  dir.create(dataset_dir)
  on.exit(unlink(dataset_dir, recursive = TRUE), add = TRUE)

  arrow::write_dataset(x, dataset_dir)
  dataset <- arrow::open_dataset(dataset_dir)

  out <- tempfile(fileext = ".xml.gz")
  write_marcxml(dataset, out, compression_level = 9L)

  expect_identical(
    as.integer(readBin(out, "raw", n = 2L)),
    c(31L, 139L)
  )
  expect_identical(read_marcxml(out), x)
})

test_that("existing reader reads genuine gzip MARCXML", {
  source_xml <- system.file(
    "extdata", "example-marcxml.xml",
    package = "marcxmlr"
  )

  bytes <- readBin(
    source_xml,
    "raw",
    n = file.info(source_xml)$size
  )

  compressed <- tempfile(fileext = ".xml.gz")
  con <- gzfile(compressed, "wb", compression = 6L)
  writeBin(bytes, con)
  close(con)

  expect_identical(
    as.integer(readBin(compressed, "raw", n = 2L)),
    c(31L, 139L)
  )

  expect_identical(
    read_marcxml(compressed),
    read_marcxml(source_xml)
  )
})
