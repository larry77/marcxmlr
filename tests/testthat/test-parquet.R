test_that("marcxml_to_parquet matches the in-memory representation", {
  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")

  output <- tempfile("marcxml-parquet-test-")
  on.exit(unlink(output, recursive = TRUE), add = TRUE)
  reference <- read_marcxml(example_marcxml_file())

  summary <- marcxml_to_parquet(
    example_marcxml_file(),
    output_dir = output,
    batch_records = 1L,
    workers = 1L,
    chunk_records = NULL,
    verbose = FALSE
  )

  files <- list.files(output, pattern = "\\.parquet$", full.names = TRUE)
  streamed <- purrr::map(files, arrow::read_parquet) |>
    purrr::list_rbind()

  expect_equal(nrow(streamed), 18L)
  expect_identical(names(streamed), canonical_columns)
  expect_identical(sort_canonical(streamed), sort_canonical(reference))
  expect_identical(summary$records, 2L)
  expect_equal(summary$rows, 18)
  expect_identical(summary$batches, 2L)
  expect_identical(summary$parquet_files, 2L)
})

test_that("automatic chunk sizing writes a valid sequential dataset", {
  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")

  output <- tempfile("marcxml-parquet-auto-")
  on.exit(unlink(output, recursive = TRUE), add = TRUE)

  summary <- marcxml_to_parquet(
    example_marcxml_file(),
    output_dir = output,
    workers = 1L,
    chunk_records = NULL,
    verbose = FALSE
  )

  expect_identical(summary$records, 2L)
  expect_identical(summary$batches, 1L)
  expect_identical(summary$parquet_files, 1L)
})

test_that("existing output is never overwritten", {
  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")

  output <- tempfile("existing-marcxml-output-")
  dir.create(output)
  marker <- file.path(output, "keep.txt")
  writeLines("keep", marker)
  on.exit(unlink(output, recursive = TRUE), add = TRUE)

  expect_error(
    marcxml_to_parquet(
      example_marcxml_file(),
      output_dir = output,
      workers = 1L,
      verbose = FALSE
    ),
    "already exists"
  )
  expect_true(file.exists(marker))
})

test_that("empty collections retain the canonical Parquet schema", {
  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")

  input <- write_test_xml(c(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
    "<collection xmlns=\"http://www.loc.gov/MARC21/slim\" />"
  ))
  output <- tempfile("empty-marcxml-output-")
  on.exit(unlink(output, recursive = TRUE), add = TRUE)

  summary <- marcxml_to_parquet(
    input,
    output_dir = output,
    workers = 1L,
    verbose = FALSE
  )
  file <- list.files(output, pattern = "\\.parquet$", full.names = TRUE)
  result <- arrow::read_parquet(file)

  expect_identical(names(result), canonical_columns)
  expect_equal(nrow(result), 0L)
  expect_identical(summary$records, 0L)
  expect_equal(summary$rows, 0)
  expect_identical(summary$parquet_files, 1L)
})

test_that("namespace-free collections can be converted", {
  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")

  input <- write_test_xml(c(
    "<collection>",
    "  <record>",
    "    <leader>00000nam a2200000 i 4500</leader>",
    "    <controlfield tag=\"001\">plain</controlfield>",
    "  </record>",
    "</collection>"
  ))
  output <- tempfile("plain-marcxml-output-")
  on.exit(unlink(output, recursive = TRUE), add = TRUE)

  summary <- marcxml_to_parquet(
    input,
    output_dir = output,
    workers = 1L,
    verbose = FALSE
  )

  result <- arrow::read_parquet(list.files(
    output,
    pattern = "\\.parquet$",
    full.names = TRUE
  ))

  expect_identical(summary$records, 1L)
  expect_identical(result$field_type, c("leader", "controlfield"))
})

test_that("failed conversion does not publish a partial dataset", {
  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")

  input <- write_test_xml(c(
    "<collection xmlns=\"http://www.loc.gov/MARC21/slim\">",
    "  <record>",
    "    <leader>00000nam a2200000 i 4500</leader>",
    "    <controlfield tag=\"001\">first</controlfield>",
    "  </record>",
    "  <record>",
    "    <leader>00000nam a2200000 i 4500</leader>",
    "    <datafield tag=\"245\" ind1=\"1\" ind2=\"0\" />",
    "  </record>",
    "</collection>"
  ))
  output <- tempfile("failed-marcxml-output-")

  expect_error(
    marcxml_to_parquet(
      input,
      output_dir = output,
      batch_records = 1L,
      workers = 1L,
      verbose = FALSE
    ),
    "without any `<subfield>`"
  )
  expect_false(file.exists(output))
})

test_that("converter rejects non-collection documents before publication", {
  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")

  standalone <- write_test_xml(c(
    "<record xmlns=\"http://www.loc.gov/MARC21/slim\">",
    "  <leader>00000nam a2200000 i 4500</leader>",
    "</record>"
  ))
  foreign <- write_test_xml(c(
    "<collection xmlns=\"https://example.org/not-marc\">",
    "</collection>"
  ))
  standalone_output <- tempfile("standalone-stream-output-")
  foreign_output <- tempfile("foreign-stream-output-")

  expect_error(
    marcxml_to_parquet(
      standalone,
      output_dir = standalone_output,
      workers = 1L,
      verbose = FALSE
    ),
    "Expected a MARCXML `<collection>`"
  )
  expect_error(
    marcxml_to_parquet(
      foreign,
      output_dir = foreign_output,
      workers = 1L,
      verbose = FALSE
    ),
    "expected <http://www.loc.gov/MARC21/slim>"
  )
  expect_false(file.exists(standalone_output))
  expect_false(file.exists(foreign_output))
})

test_that("converter arguments fail clearly", {
  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")

  expect_error(
    marcxml_to_parquet(
      example_marcxml_file(),
      output_dir = "",
      workers = 1L
    ),
    "output_dir"
  )
  expect_error(
    marcxml_to_parquet(
      example_marcxml_file(),
      output_dir = tempfile(),
      batch_records = 0L,
      workers = 1L
    ),
    "batch_records"
  )
  expect_error(
    marcxml_to_parquet(
      example_marcxml_file(),
      output_dir = tempfile(),
      workers = 0L
    ),
    "workers"
  )
})

test_that("parallel conversion can be enabled explicitly", {
  skip_if(Sys.getenv("RUN_MARCXML_PARALLEL_TESTS") != "true")
  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")
  skip_if_not_installed("future")
  skip_if_not_installed("future.mirai")
  skip_if_not_installed("futurize")
  skip_if_not_installed("furrr")
  skip_if_not_installed("mori")
  skip_if(future::availableCores() < 2L)

  output <- tempfile("parallel-marcxml-output-")
  on.exit(unlink(output, recursive = TRUE), add = TRUE)
  reference <- read_marcxml(example_marcxml_file())

  marcxml_to_parquet(
    example_marcxml_file(),
    output_dir = output,
    batch_records = 2L,
    workers = 2L,
    chunk_records = 1L,
    verbose = FALSE
  )

  files <- list.files(output, pattern = "\\.parquet$", full.names = TRUE)
  streamed <- purrr::map(files, arrow::read_parquet) |>
    purrr::list_rbind()

  expect_identical(sort_canonical(streamed), sort_canonical(reference))
})
