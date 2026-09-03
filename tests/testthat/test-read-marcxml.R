test_that("read_marcxml returns the canonical schema and types", {
  result <- read_marcxml(example_marcxml_file())

  expect_s3_class(result, "tbl_df")
  expect_identical(names(result), canonical_columns)
  expect_equal(nrow(result), 18L)

  integer_columns <- c(
    "record_id",
    "field_order",
    "field_occurrence",
    "subfield_order",
    "subfield_occurrence"
  )
  character_columns <- setdiff(canonical_columns, integer_columns)

  expect_true(all(purrr::map_lgl(result[integer_columns], is.integer)))
  expect_true(all(purrr::map_lgl(result[character_columns], is.character)))
})

test_that("leaders and control fields use non-applicable values consistently", {
  result <- read_marcxml(example_marcxml_file())
  leaders <- result[result$field_type == "leader", ]
  controls <- result[result$field_type == "controlfield", ]

  expect_equal(nrow(leaders), 2L)
  expect_true(all(leaders$tag == "LDR"))
  expect_true(all(leaders$field_order == 0L))
  expect_true(all(leaders$field_occurrence == 1L))
  expect_true(all(is.na(leaders$subfield_code)))
  expect_true(all(is.na(leaders$ind1)))
  expect_true(all(is.na(leaders$ind2)))
  expect_true(all(is.na(leaders$subfield_order)))
  expect_true(all(is.na(leaders$subfield_occurrence)))

  expect_true(all(is.na(controls$subfield_code)))
  expect_true(all(is.na(controls$ind1)))
  expect_true(all(is.na(controls$ind2)))
  expect_true(all(is.na(controls$subfield_order)))
  expect_true(all(is.na(controls$subfield_occurrence)))
})

test_that("field and subfield repetition are not collapsed", {
  result <- read_marcxml(example_marcxml_file())
  subjects <- result[result$record_id == 1L & result$tag == "650", ]
  links <- result[result$record_id == 1L & result$tag == "856", ]

  expect_identical(subjects$field_order, c(4L, 4L, 5L))
  expect_identical(subjects$field_occurrence, c(1L, 1L, 2L))

  expect_identical(links$subfield_code, c("u", "y", "y"))
  expect_identical(links$subfield_order, 1:3)
  expect_identical(links$subfield_occurrence, c(1L, 1L, 2L))
  expect_identical(
    links$value,
    c(
      "https://example.org/item/1",
      "Full text",
      "Alternate access"
    )
  )
})

test_that("repeated control fields and empty subfields remain explicit", {
  file <- write_test_xml(c(
    "<record xmlns=\"http://www.loc.gov/MARC21/slim\">",
    "  <leader>00000nam a2200000 i 4500</leader>",
    "  <controlfield tag=\"006\">first</controlfield>",
    "  <controlfield tag=\"006\">second</controlfield>",
    "  <datafield tag=\"500\" ind1=\" \" ind2=\" \">",
    "    <subfield code=\"a\"></subfield>",
    "  </datafield>",
    "</record>"
  ))

  result <- read_marcxml(file)
  controls <- result[result$field_type == "controlfield", ]
  note <- result[result$tag == "500", ]

  expect_identical(controls$tag, c("006", "006"))
  expect_identical(controls$field_occurrence, c(1L, 2L))
  expect_identical(controls$value, c("first", "second"))
  expect_identical(note$value, "")
  expect_identical(note$subfield_order, 1L)
  expect_identical(note$subfield_occurrence, 1L)
})

test_that("source field order, indicators, whitespace, and UTF-8 are preserved", {
  result <- read_marcxml(example_marcxml_file())
  record_one_fields <- unique(result$field_order[result$record_id == 1L])
  record_two_fields <- unique(result$field_order[result$record_id == 2L])

  expect_identical(record_one_fields, 0:6)
  expect_identical(record_two_fields, 0:5)

  subject <- result[
    result$record_id == 1L & result$tag == "650" &
      result$field_order == 4L,
  ]
  note <- result[result$record_id == 2L & result$tag == "500", ]
  title <- result[result$record_id == 2L & result$tag == "245", ]

  expect_true(all(subject$ind1 == " "))
  expect_true(all(subject$ind2 == "0"))
  expect_identical(
    note$value,
    "  Leading and trailing spaces are preserved.  "
  )
  expect_identical(title$value, "Café metadata & reproducible examples")
})

test_that("n_max selects records and zero preserves the schema", {
  first <- read_marcxml(example_marcxml_file(), n_max = 1L)
  empty <- read_marcxml(example_marcxml_file(), n_max = 0L)

  expect_identical(unique(first$record_id), 1L)
  expect_equal(nrow(first), 11L)
  expect_identical(names(empty), canonical_columns)
  expect_equal(nrow(empty), 0L)
})

test_that("standalone and namespace-free records are accepted", {
  file <- write_test_xml(c(
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
    "<record>",
    "  <leader>00000nam a2200000 i 4500</leader>",
    "  <controlfield tag=\"001\">standalone</controlfield>",
    "  <datafield tag=\"245\" ind1=\"0\" ind2=\"0\">",
    "    <subfield code=\"a\">Standalone record</subfield>",
    "  </datafield>",
    "</record>"
  ))

  result <- read_marcxml(file)

  expect_equal(nrow(result), 3L)
  expect_identical(result$field_type, c("leader", "controlfield", "datafield"))
  expect_identical(result$field_order, 0:2)
})

test_that("sequential chunk sizes do not change results", {
  reference <- read_marcxml(example_marcxml_file(), workers = 1L)
  chunked <- read_marcxml(
    example_marcxml_file(),
    workers = 1L,
    chunk_records = 1L
  )

  expect_identical(chunked, reference)
})

test_that("the public API remains deliberately small", {
  expect_setequal(
    getNamespaceExports("marcxmlr"),
    c("read_marcxml", "marcxml_to_parquet")
  )

  expect_identical(formals(read_marcxml)$workers, 1L)
  expect_identical(formals(marcxml_to_parquet)$workers, 1L)
})

test_that("parallel in-memory parsing can be enabled explicitly", {
  skip_if(Sys.getenv("RUN_MARCXML_PARALLEL_TESTS") != "true")
  skip_if_not_installed("future")
  skip_if_not_installed("future.mirai")
  skip_if_not_installed("futurize")
  skip_if_not_installed("furrr")
  skip_if_not_installed("mori")
  skip_if(future::availableCores() < 2L)

  reference <- read_marcxml(example_marcxml_file(), workers = 1L)
  parallel <- read_marcxml(
    example_marcxml_file(),
    workers = 2L,
    chunk_records = 1L
  )

  expect_identical(parallel, reference)
})

test_that("invalid arguments fail clearly", {
  expect_error(read_marcxml(character()), "one non-missing path", fixed = TRUE)
  expect_error(read_marcxml(NA_character_), "one non-missing path", fixed = TRUE)
  expect_error(read_marcxml("not-present.xml"), "does not exist", fixed = TRUE)
  expect_error(read_marcxml(example_marcxml_file(), n_max = -1), "n_max")
  expect_error(read_marcxml(example_marcxml_file(), workers = 0), "workers")
  expect_error(
    read_marcxml(example_marcxml_file(), chunk_records = 0),
    "chunk_records"
  )
})
