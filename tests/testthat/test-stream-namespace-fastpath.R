test_that("stream namespace fast path matches generic repair", {
  ns <- .marcxml_namespace

  cases <- list(
    list(
      text = "<record><leader>L</leader></record>",
      root_namespace = ns
    ),
    list(
      text = '<record id="r1"><leader>L</leader></record>',
      root_namespace = ns
    ),
    list(
      text = paste0(
        '<record xmlns="', ns, '"><leader>L</leader></record>'
      ),
      root_namespace = ns
    ),
    list(
      text = paste0(
        '<m:record xmlns:m="', ns, '">',
        "<m:leader>L</m:leader></m:record>"
      ),
      root_namespace = ns
    ),
    list(
      text = paste0(
        '<record xmlns:x="urn:x">',
        "<leader>L</leader></record>"
      ),
      root_namespace = ns
    ),
    list(
      text = "<record><leader>L</leader></record>",
      root_namespace = ""
    ),
    list(
      text = "<recording><leader>L</leader></recording>",
      root_namespace = ns
    )
  )

  for (case in cases) {
    expect_identical(
      .ensure_stream_record_namespace(
        case$text,
        case$root_namespace
      ),
      .ensure_record_namespace(
        case$text,
        case$root_namespace
      )
    )
  }
})

test_that("stream namespace fast path inserts the MARC namespace exactly", {
  ns <- .marcxml_namespace
  text <- paste0(
    '<record id="r1" xml:space="preserve">',
    "<leader>  L  </leader>",
    "</record>"
  )

  expect_identical(
    .ensure_stream_record_namespace(text, ns),
    paste0(
      '<record id="r1" xml:space="preserve" xmlns="',
      ns,
      '">',
      "<leader>  L  </leader>",
      "</record>"
    )
  )
})

test_that("stream namespace fast path falls back around namespace text", {
  ns <- .marcxml_namespace
  text <- paste0(
    "<record>",
    "<leader>L</leader>",
    '<controlfield tag="001">contains xmlns text</controlfield>',
    "</record>"
  )

  expect_identical(
    .ensure_stream_record_namespace(text, ns),
    .ensure_record_namespace(text, ns)
  )
})
