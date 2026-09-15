test_that("native worker chunks preserve source order and restore the future plan", {
  skip_if(Sys.getenv("RUN_MARCXML_PARALLEL_TESTS") != "true")
  for (package in c("future", "future.mirai", "futurize", "furrr", "mori")) {
    skip_if_not_installed(package)
  }
  skip_if(future::availableCores() < 2L)
  record <- paste0('<record><leader>L</leader><controlfield tag="001">x</controlfield>',
    '<datafield tag="650" ind1=" " ind2="0"><subfield code="a">one</subfield>',
    '<subfield code="a">two</subfield></datafield></record>')
  input <- write_test_xml(c('<collection>', rep(record, 540L), '</collection>'))
  previous <- future::plan()
  reference <- reference_read(input)
  result <- read_marcxml(input, workers = 2L, chunk_records = 270L)
  expect_identical(result, reference)
  expect_true(isTRUE(all.equal(future::plan(), previous)))

  invalid <- write_test_xml(c('<collection>', rep(record, 270L),
    '<record><leader>L</leader><controlfield/></record>', '</collection>'))
  expect_error(read_marcxml(invalid, workers = 2L, chunk_records = 270L),
               'without a `tag`', fixed = TRUE)
  expect_true(isTRUE(all.equal(future::plan(), previous)))
})
