test_that("native stream reader yields bounded record batches", {
  records <- rep(
    paste0(
      "<record><leader>L</leader>",
      '<controlfield tag="001">x</controlfield></record>'
    ),
    5L
  )

  input <- write_test_xml(
    c("<collection>", records, "</collection>")
  )

  reader <- .native_marcxml_reader_open(input)
  expect_type(reader, "externalptr")

  first <- .native_marcxml_reader_next(reader, 2L)
  second <- .native_marcxml_reader_next(reader, 2L)
  third <- .native_marcxml_reader_next(reader, 2L)
  done <- .native_marcxml_reader_next(reader, 2L)

  expect_length(first, 2L)
  expect_length(second, 2L)
  expect_length(third, 1L)
  expect_length(done, 0L)

  extracted <- c(first, second, third)

  parsed <- .native_marcxml_records(
    extracted,
    seq_along(extracted)
  )

  expect_identical(
    parsed,
    reference_read(input)
  )

  .native_marcxml_reader_close(reader)

  expect_error(
    .native_marcxml_reader_next(reader, 1L),
    "closed",
    fixed = TRUE
  )
})

test_that("native stream reader declines inputs outside its safe subset", {
  cases <- c(
    "<collection><record>",
    "<collection><wrong/></collection>",
    paste0(
      '<collection xmlns="urn:foreign">',
      "<record><leader>L</leader></record>",
      "</collection>"
    ),
    paste0(
      '<!DOCTYPE collection [<!ENTITY e "x">]>',
      "<collection>",
      "<record><leader>&e;</leader></record>",
      "</collection>"
    ),
    paste0(
      "<collection>",
      "<record><leader>L</leader>",
      '<controlfield xmlns:x="urn:x" x:tag="001">x</controlfield>',
      "</record>",
      "</collection>"
    )
  )

  for (text in cases) {
    input <- write_test_xml(text)
    expect_null(
      .native_marcxml_reader_open(input)
    )
  }
})

test_that("native stream reader can be disabled", {
  input <- write_test_xml(
    paste0(
      "<collection>",
      "<record><leader>L</leader></record>",
      "</collection>"
    )
  )

  old <- options(marcxmlr.native = FALSE)
  on.exit(options(old))

  expect_null(
    .native_marcxml_reader_open(input)
  )
})

test_that("native stream conversion matches the legacy pipeline", {
  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")

  records <- rep(
    paste0(
      "<record><leader>L</leader>",
      '<datafield tag="650" ind1=" " ind2="0">',
      '<subfield code="a">x</subfield>',
      '<subfield code="a">y</subfield>',
      "</datafield></record>"
    ),
    270L
  )

  input <- write_test_xml(
    c("<collection>", records, "</collection>")
  )

  outputs <- c(
    tempfile(),
    tempfile()
  )

  on.exit(
    unlink(outputs, recursive = TRUE),
    add = TRUE
  )

  old <- options(
    marcxmlr.native = TRUE,
    marcxmlr.native_stream = TRUE
  )
  on.exit(options(old), add = TRUE)

  fast <- marcxml_to_parquet(
    input,
    outputs[[1L]],
    batch_records = 263L,
    chunk_records = 257L,
    verbose = FALSE
  )

  options(
    marcxmlr.native = FALSE,
    marcxmlr.native_stream = FALSE
  )

  legacy <- marcxml_to_parquet(
    input,
    outputs[[2L]],
    batch_records = 263L,
    chunk_records = 257L,
    verbose = FALSE
  )

  read_parts <- function(path) {
    files <- sort(
      list.files(
        path,
        pattern = "\\.parquet$",
        full.names = TRUE
      )
    )

    purrr::list_rbind(
      purrr::map(
        files,
        arrow::read_parquet
      )
    )
  }

  expect_identical(
    fast[c(
      "records",
      "rows",
      "batches",
      "parquet_files"
    )],
    legacy[c(
      "records",
      "rows",
      "batches",
      "parquet_files"
    )]
  )

  expect_identical(
    read_parts(outputs[[1L]]),
    read_parts(outputs[[2L]])
  )
})
