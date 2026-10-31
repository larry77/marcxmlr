testthat::test_that("in-memory strategy overrides warn and do not change output", {
  file <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  testthat::expect_true(nzchar(file))

  reference <- marcxmlr::read_marcxml(file)
  testthat::expect_identical(
    marcxmlr::read_marcxml(file, strategy = "auto"), reference
  )

  testthat::expect_warning(
    direct <- marcxmlr::read_marcxml(file, strategy = "direct"),
    "only supported"
  )
  testthat::expect_warning(
    indexed <- marcxmlr::read_marcxml(file, strategy = "indexed"),
    "only supported"
  )
  testthat::expect_identical(direct, reference)
  testthat::expect_identical(indexed, reference)
})

testthat::test_that("single-file Parquet strategy overrides preserve canonical data", {
  testthat::skip_if_not_installed("arrow")
  file <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  testthat::expect_true(nzchar(file))

  work <- tempfile("marcxmlr-strategy-")
  dir.create(work)
  on.exit(unlink(work, recursive = TRUE), add = TRUE)

  read_data <- function(path) {
    arrow::open_dataset(path) |>
      dplyr::collect() |>
      dplyr::arrange(dplyr::across(dplyr::everything()))
  }

  for (strategy in c("auto", "direct", "indexed")) {
    marcxmlr::marcxml_to_parquet(
      file,
      output_dir = file.path(work, strategy),
      workers = 1L,
      batch_records = 10L,
      strategy = strategy,
      verbose = FALSE
    )
  }

  reference <- read_data(file.path(work, "direct"))
  testthat::expect_identical(read_data(file.path(work, "auto")), reference)
  testthat::expect_identical(read_data(file.path(work, "indexed")), reference)

  testthat::expect_error(
    marcxmlr::marcxml_to_parquet(
      file, file.path(work, "bad-filter"),
      filter = marcxmlr::marc_has("650"),
      strategy = "direct", verbose = FALSE
    ),
    "cannot be used with MARC-aware filters"
  )

  testthat::expect_error(
    marcxmlr::marcxml_to_parquet(
      file, file.path(work, "bad-recovery"),
      on_marc_error = "skip",
      strategy = "indexed", verbose = FALSE
    ),
    "does not support MARC recovery"
  )

  testthat::expect_error(
    marcxmlr::marcxml_to_parquet(
      file, file.path(work, "bad-chunk"),
      chunk_records = 10L,
      strategy = "indexed", verbose = FALSE
    ),
    "chunk_records = NULL"
  )
})

testthat::test_that("parallel multi-file auto strategy agrees with both engines", {
  testthat::skip_on_cran()
  for (dependency in c("arrow", "future", "future.mirai", "futurize", "mori")) {
    testthat::skip_if_not_installed(dependency)
  }

  file <- system.file("extdata", "example-marcxml.xml", package = "marcxmlr")
  testthat::expect_true(nzchar(file))

  work <- tempfile("marcxmlr-strategy-parallel-")
  dir.create(work)
  on.exit(unlink(work, recursive = TRUE), add = TRUE)

  files <- file.path(work, c("input-01.xml", "input-02.xml"))
  testthat::expect_true(all(file.copy(file, files)))

  for (strategy in c("auto", "direct", "indexed")) {
    marcxmlr::marcxml_to_parquet(
      files,
      output_dir = file.path(work, strategy),
      workers = 2L,
      batch_records = 10L,
      strategy = strategy,
      verbose = FALSE
    )
  }

  read_data <- function(path) {
    arrow::open_dataset(path) |>
      dplyr::collect() |>
      dplyr::arrange(dplyr::across(dplyr::everything()))
  }
  reference <- read_data(file.path(work, "direct"))
  testthat::expect_identical(read_data(file.path(work, "auto")), reference)
  testthat::expect_identical(read_data(file.path(work, "indexed")), reference)
})
