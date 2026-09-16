# Compare the accelerated path with the unchanged released parser, including
# errors. These tests deliberately cover inputs outside ordinary MARC tags.
test_that("native routines are registered and ordinary records use C", {
  texts <- .extract_marcxml_record_texts(example_marcxml_file(), Inf)
  result <- .Call(C_marcxml_parse_records, texts, seq_along(texts))
  expect_type(result, "list")
  expect_identical(
    tibble::new_tibble(result, nrow = length(result[[1L]])),
    reference_read(example_marcxml_file())
  )
  expect_false(getLoadedDLLs()[["marcxmlr"]][["dynamicLookup"]])
})

test_that("native chunks preserve rich text and arbitrary occurrence keys", {
  text <- paste0(
    '<record xmlns="http://www.loc.gov/MARC21/slim">',
    '<!-- before leader --><leader>  A <![CDATA[B]]> C  </leader>',
    '<controlfield tag="long-tag">Caf\u00e9 &amp; tea</controlfield>',
    '<controlfield tag="long-tag"/>',
    '<datafield tag="long-tag" ind1=" " ind2="long">',
    '<subfield code="code-long"> </subfield>',
    '<subfield code="\u0436">\u6771\u4eac &#x1F642;</subfield>',
    '<subfield code="code-long">a<!-- ignored -->b<?x y?>c</subfield>',
    '</datafield>',
    '<datafield tag="long-tag" ind1="x" ind2=" ">',
    '<subfield code="code-long"/>',
    '<subfield code="code-long"><![CDATA[  \t ]]></subfield>',
    '</datafield></record>'
  )
  file <- write_test_xml(text)
  native <- native_read(file)
  expect_identical(native, reference_read(file))
  expect_identical(native$field_occurrence, c(1L, 1L, 2L, 1L, 1L, 1L, 2L, 2L))
  expect_identical(native$subfield_occurrence, c(NA_integer_, NA_integer_,
    NA_integer_, 1L, 1L, 2L, 1L, 2L))
  expect_type(.Call(C_marcxml_parse_records, text, 1L), "list")
})

test_that("native batches preserve IDs and order across internal boundaries", {
  set.seed(4123)
  records <- purrr::map_chr(seq_len(270L), function(i) {
    fields <- purrr::map_chr(seq_len(sample.int(8L, 1L)), function(j) {
      tag <- sample(c("001", "650", "x", "650-long"), 1L)
      if (sample(c(TRUE, FALSE), 1L)) {
        return(sprintf('<controlfield tag="%s">%d</controlfield>', tag, j))
      }
      codes <- sample(c("a", "b", "long", "1"), sample.int(6L, 1L), TRUE)
      paste0('<datafield tag="', tag, '" ind1=" " ind2="0">',
        paste0('<subfield code="', codes, '">', i, '</subfield>', collapse = ''),
        '</datafield>')
    })
    paste0('<record><leader>L</leader>', paste0(fields, collapse = ''), '</record>')
  })
  file <- write_test_xml(paste0('<collection>', paste0(records, collapse = ''),
                                '</collection>'))
  reference <- reference_read(file)
  expect_identical(native_read(file), reference)
  expect_identical(native_read(file, chunk_records = 13L), reference)
  expect_identical(native_read(file, n_max = 257L), reference[reference$record_id <= 257L, ])
  expect_identical(.native_marcxml_records(records, 260:270, 900:910)$record_id,
    rep(900:910, tabulate(reference$record_id)[260:270]))
})

test_that("namespaces, attributes and namespace repairs retain reference behaviour", {
  cases <- c(
    '<collection xmlns="http://www.loc.gov/MARC21/slim"><record><leader>L</leader></record></collection>',
    '<m:collection xmlns:m="http://www.loc.gov/MARC21/slim"><m:record><m:leader>L</m:leader><m:controlfield tag="001">x</m:controlfield></m:record></m:collection>',
    '<record xmlns:x="urn:x"><leader>L</leader><controlfield x:tag="001">x</controlfield></record>',
    '<record><leader xml:space="preserve">  </leader><controlfield tag="001" extra="ok">\n\t</controlfield></record>',
    '<record><leader/><controlfield tag="001">a<![CDATA[b]]>c</controlfield></record>',
    '<record xmlns:m="http://www.loc.gov/MARC21/slim"><leader>L</leader><m:controlfield tag="001">x</m:controlfield></record>',
    '<!DOCTYPE record [<!ENTITY e "expanded">]><record><leader>&e;</leader></record>'
  )
  capture <- function(fun, file) {
    tryCatch(fun(file), error = function(e) conditionMessage(e))
  }
  for (text in cases) {
    file <- write_test_xml(text)
    expect_identical(capture(native_read, file), capture(reference_read, file))
  }
})

test_that("native rejection preserves reference diagnostics and their precedence", {
  bad <- c(
    '<record/>',
    '<record><leader/><leader/></record>',
    '<record><controlfield tag="001"/><leader/></record>',
    '<record><leader/><unknown/><other/></record>',
    '<record><leader><x/></leader></record>',
    '<record><leader/><controlfield/></record>',
    '<record><leader/><datafield tag="x" ind2="0"/><controlfield/></record>',
    '<record><leader/><datafield tag="x" ind1="0"/></record>',
    '<record><leader/><datafield tag="x" ind1="" ind2="0"/></record>',
    '<record><leader/><datafield tag="x" ind1="0" ind2="0"/></record>',
    '<record><leader/><datafield tag="x" ind1="0" ind2="0"><wrong/></datafield></record>',
    '<record><leader/><datafield tag="x" ind1="0" ind2="0"><subfield/></datafield></record>',
    '<record><leader/><datafield tag="x" ind1="0" ind2="0"><subfield code="a"><x/></subfield></datafield></record>',
    '<record><leader/><x:extra xmlns:x="urn:foreign"/></record>'
  )
  for (text in bad) {
    file <- write_test_xml(paste0('<collection><record><leader>ok</leader></record>',
                                  text, '</collection>'))
    ref <- tryCatch(reference_read(file), error = identity)
    got <- tryCatch(native_read(file), error = identity)
    expect_s3_class(got, "error")
    expect_identical(class(got), class(ref))
    expect_identical(conditionMessage(got), conditionMessage(ref))
    expect_identical(native_read(file, n_max = 1L), reference_read(file, n_max = 1L))
    expect_identical(native_read(file, n_max = 0L), reference_read(file, n_max = 0L))
  }
})

test_that("malformed XML and invalid collection children still fail before n_max", {
  for (text in c('<collection><record>',
                 '<collection><record><leader/></record><wrong/></collection>')) {
    file <- write_test_xml(text)
    for (limit in c(0L, 1L, Inf)) {
      ref <- tryCatch(reference_read(file, n_max = limit), error = identity)
      got <- tryCatch(native_read(file, n_max = limit), error = identity)
      expect_s3_class(got, "error")
      expect_identical(conditionMessage(got), conditionMessage(ref))
    }
  }
})

test_that("native code handles GC and validates its internal boundary", {
  expect_error(.Call(C_marcxml_parse_records, "<record/>", 1), "Invalid native")
  expect_error(.Call(C_marcxml_parse_records, NA_character_, 1L), "Invalid native")
  expect_error(.Call(C_marcxml_parse_records, "<record/>", 0L), "Invalid native")
  old <- gctorture2(10L)
  on.exit(gctorture2(old))
  got <- .Call(C_marcxml_parse_records,
    '<record><leader>L</leader><controlfield tag="001">x</controlfield></record>', 1L)
  gctorture2(old)
  expect_identical(got$value, c("L", "x"))
})

test_that("native and reference streaming produce identical datasets and summaries", {
  skip_if_not_installed("XML")
  skip_if_not_installed("arrow")
  old <- options(marcxmlr.native = TRUE)
  on.exit(options(old))
  outputs <- c(tempfile(), tempfile())
  on.exit(unlink(outputs, recursive = TRUE), add = TRUE)
  records <- rep('<record><leader>L</leader><datafield tag="650" ind1=" " ind2="0"><subfield code="a">x</subfield><subfield code="a">y</subfield></datafield></record>', 270L)
  input <- write_test_xml(c('<collection>', records, '</collection>'))
  results <- purrr::map(seq_along(outputs), function(i) {
    options(marcxmlr.native = i == 1L)
    summary <- marcxml_to_parquet(input, outputs[[i]], batch_records = 263L,
                                  chunk_records = 257L, verbose = FALSE)
    files <- list.files(outputs[[i]], full.names = TRUE)
    list(summary = summary[c("records", "rows", "batches", "parquet_files")],
         rows = purrr::list_rbind(purrr::map(files, arrow::read_parquet)),
         files = basename(files))
  })
  expect_identical(results[[1L]], results[[2L]])
})

test_that("prefix-free namespace XPath does not require namespace discovery", {
  inputs <- c(
    '<collection xmlns="http://www.loc.gov/MARC21/slim"><record><leader>L</leader></record></collection>',
    '<m:collection xmlns:m="http://www.loc.gov/MARC21/slim"><m:record><m:leader>L</m:leader></m:record></m:collection>'
  )

  for (text in inputs) {
    doc <- xml2::read_xml(text)
    records <- xml2::xml_children(xml2::xml_root(doc))
    expect_identical(
      xml2::xml_find_chr(records, "namespace-uri(.)", ns = character()),
      xml2::xml_find_chr(records, "namespace-uri(.)")
    )
  }
})

test_that("native parser handles a large individual record and Unicode edges", {
  n <- 4096L
  codes <- rep(c("a", "b", "long-code", "\u0436"), length.out = n)
  values <- paste0("e\u0301-\U0001F642-", seq_len(n))
  subfields <- paste0(
    '<subfield code="', codes, '">', values, '</subfield>',
    collapse = ""
  )
  text <- paste0(
    '<record><leader>L</leader><datafield tag="650-long" ind1=" " ind2="0">',
    subfields,
    '</datafield></record>'
  )
  file <- write_test_xml(text)

  expect_identical(native_read(file), reference_read(file))
  direct <- .Call(C_marcxml_parse_records, text, 1L)
  expect_type(direct, "list")
  expect_identical(length(direct[[1L]]), n + 1L)
  expect_identical(tail(direct[[11L]], 4L), rep(1024L, 4L))
})
