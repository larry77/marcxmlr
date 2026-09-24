test_that("multiple MARCXML files form one dataset with global record ids", {
  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")

  input_dir <- tempfile("marcxml-multiple-input-")
  dir.create(input_dir)
  on.exit(unlink(input_dir, recursive = TRUE), add = TRUE)

  inputs <- file.path(input_dir, c("part-01.xml", "part-02.xml"))
  expect_true(all(file.copy(example_marcxml_file(), inputs)))

  output <- tempfile("marcxml-multiple-output-")
  on.exit(unlink(output, recursive = TRUE), add = TRUE)

  summary <- marcxml_to_parquet(
    inputs,
    output_dir = output,
    workers = 1L,
    verbose = FALSE
  )

  files <- sort(list.files(
    output,
    pattern = "\\.parquet$",
    full.names = TRUE
  ))
  result <- purrr::map(files, arrow::read_parquet) |>
    purrr::list_rbind()

  reference <- read_marcxml(example_marcxml_file())
  second <- reference
  second$record_id <- second$record_id + max(reference$record_id)
  expected <- purrr::list_rbind(list(reference, second))

  expect_identical(
    sort_canonical(result),
    sort_canonical(expected)
  )
  expect_identical(
    summary$input_file,
    normalizePath(inputs, winslash = "/")
  )
  expect_true(
    all(summary$output_dir == normalizePath(output, winslash = "/"))
  )
  expect_identical(summary$records, c(2L, 2L))
  expect_identical(sort(unique(result$record_id)), 1:4)
})

test_that("MARCXML glob input matches an explicit sorted vector", {
  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")

  input_dir <- tempfile("marcxml-glob-input-")
  dir.create(input_dir)
  on.exit(unlink(input_dir, recursive = TRUE), add = TRUE)

  inputs <- file.path(input_dir, c("b.xml", "a.xml"))
  expect_true(all(file.copy(example_marcxml_file(), inputs)))

  output_explicit <- tempfile("marcxml-explicit-output-")
  output_glob <- tempfile("marcxml-glob-output-")
  on.exit(unlink(output_explicit, recursive = TRUE), add = TRUE)
  on.exit(unlink(output_glob, recursive = TRUE), add = TRUE)

  explicit <- sort(inputs)
  marcxml_to_parquet(
    explicit,
    output_dir = output_explicit,
    workers = 1L,
    verbose = FALSE
  )
  glob_summary <- marcxml_to_parquet(
    file.path(input_dir, "*.xml"),
    output_dir = output_glob,
    workers = 1L,
    verbose = FALSE
  )

  read_dataset_parts <- function(path) {
    purrr::map(
      sort(list.files(
        path,
        pattern = "\\.parquet$",
        full.names = TRUE
      )),
      arrow::read_parquet
    ) |>
      purrr::list_rbind()
  }

  explicit_result <- read_dataset_parts(output_explicit)
  glob_result <- read_dataset_parts(output_glob)

  expect_identical(
    sort_canonical(glob_result),
    sort_canonical(explicit_result)
  )
  expect_identical(
    glob_summary$input_file,
    normalizePath(explicit, winslash = "/")
  )
})

test_that("multiple-file input validation fails clearly", {
  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")

  input <- example_marcxml_file()

  expect_error(
    marcxml_to_parquet(
      c(input, input),
      output_dir = tempfile(),
      workers = 1L,
      verbose = FALSE
    ),
    "same file more than once"
  )

  expect_error(
    marcxml_to_parquet(
      tempfile(pattern = "missing-marcxml-*.xml"),
      output_dir = tempfile(),
      workers = 1L,
      verbose = FALSE
    ),
    "did not match any file"
  )

  input_dir <- tempfile("marcxml-directory-input-")
  dir.create(input_dir)
  on.exit(unlink(input_dir, recursive = TRUE), add = TRUE)

  expect_error(
    marcxml_to_parquet(
      input_dir,
      output_dir = tempfile(),
      workers = 1L,
      verbose = FALSE
    ),
    "Use a glob"
  )

  second <- tempfile(fileext = ".xml")
  file.copy(input, second)
  on.exit(unlink(second), add = TRUE)

  expect_error(
    marcxml_to_parquet(
      c(input, second),
      output_dir = tempfile(),
      workers = 1L,
      chunk_records = 1L,
      verbose = FALSE
    ),
    "not supported with multiple MARCXML files"
  )
})

test_that("file-level parallel conversion matches sequential multi-file conversion", {
  skip_if(Sys.getenv("RUN_MARCXML_PARALLEL_TESTS") != "true")
  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")
  skip_if_not_installed("future")
  skip_if_not_installed("future.mirai")
  skip_if_not_installed("futurize")
  skip_if_not_installed("furrr")
  skip_if_not_installed("mori")
  skip_if(future::availableCores() < 2L)

  input_dir <- tempfile("marcxml-parallel-files-")
  dir.create(input_dir)
  on.exit(unlink(input_dir, recursive = TRUE), add = TRUE)

  inputs <- file.path(input_dir, c("part-01.xml", "part-02.xml"))
  expect_true(all(file.copy(example_marcxml_file(), inputs)))

  sequential_output <- tempfile("marcxml-files-sequential-")
  parallel_output <- tempfile("marcxml-files-parallel-")
  on.exit(unlink(sequential_output, recursive = TRUE), add = TRUE)
  on.exit(unlink(parallel_output, recursive = TRUE), add = TRUE)

  marcxml_to_parquet(
    inputs,
    output_dir = sequential_output,
    workers = 1L,
    verbose = FALSE
  )
  previous <- future::plan()
  marcxml_to_parquet(
    inputs,
    output_dir = parallel_output,
    workers = 2L,
    verbose = FALSE
  )
  expect_true(isTRUE(all.equal(future::plan(), previous)))

  read_dataset_parts <- function(path) {
    purrr::map(
      sort(list.files(
        path,
        pattern = "\\.parquet$",
        full.names = TRUE
      )),
      arrow::read_parquet
    ) |>
      purrr::list_rbind()
  }

  sequential <- read_dataset_parts(sequential_output)
  parallel <- read_dataset_parts(parallel_output)

  expect_identical(
    sort_canonical(parallel),
    sort_canonical(sequential)
  )
})
