test_that("record parsing errors identify the source file and record", {
  bad_record <- paste0(
    '<record>',
    '<leader>L</leader>',
    '<datafield tag="650" ind1=" " ind2="0"></datafield>',
    '</record>'
  )

  expect_error(
    marcxmlr:::.parse_marcxml_record_with_context(
      record = bad_record,
      record_id = 7L,
      source_file = "catalogue.xml",
      record_number = 7L
    ),
    "MARCXML parsing failed in file 'catalogue.xml', record 7"
  )
})

test_that("context distinguishes file record number from global record_id", {
  bad_record <- paste0(
    '<record>',
    '<leader>L</leader>',
    '<datafield tag="650" ind1=" " ind2="0"></datafield>',
    '</record>'
  )

  expect_error(
    marcxmlr:::.parse_marcxml_record_with_context(
      record = bad_record,
      record_id = 1007L,
      source_file = "part-02.xml",
      record_number = 7L
    ),
    "record 7 \\(global record_id 1007\\)"
  )
})
