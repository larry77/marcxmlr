test_that("diagnose_canonical accepts a clean canonical representation", {
  x <- canonical_writer_fixture()
  diagnostics <- diagnose_canonical(x)

  expect_s3_class(diagnostics, "tbl_df")
  expect_named(
    diagnostics,
    c(
      "severity", "code", "message",
      "record_id", "field_order", "subfield_order"
    )
  )
  expect_equal(nrow(diagnostics), 0L)
})

test_that("diagnose_canonical requires the canonical columns", {
  x <- canonical_writer_fixture()
  x$ind2 <- NULL

  diagnostics <- diagnose_canonical(x)

  expect_true(any(diagnostics$severity == "error"))
  expect_true("missing_columns" %in% diagnostics$code)
})

test_that("diagnose_canonical rejects ambiguous field instances", {
  x <- canonical_writer_fixture()
  idx <- which(x$record_id == 1L & x$field_order == 2L)
  x$ind1[idx[[2L]]] <- "2"

  diagnostics <- diagnose_canonical(x)

  expect_true("conflicting_indicators" %in% diagnostics$code)
})

test_that("diagnose_canonical rejects duplicate subfield order", {
  x <- canonical_writer_fixture()
  idx <- which(x$record_id == 1L & x$field_order == 4L)
  x$subfield_order[idx[[2L]]] <- x$subfield_order[idx[[1L]]]

  diagnostics <- diagnose_canonical(x)

  expect_true("duplicate_subfield_order" %in% diagnostics$code)
})

test_that("diagnose_canonical requires one leader per represented record", {
  x <- canonical_writer_fixture()
  x <- x[!(x$record_id == 2L & x$field_type == "leader"), ]

  diagnostics <- diagnose_canonical(x)

  expect_true("leader_count" %in% diagnostics$code)
})

test_that("record subsetting is warning-level", {
  x <- canonical_writer_fixture()
  x <- x[x$record_id == 2L, ]

  diagnostics <- diagnose_canonical(x)

  expect_false(any(diagnostics$severity == "error"))
  expect_true("record_id_will_renumber" %in% diagnostics$code)
})

test_that("field deletion diagnoses renumbering and stale occurrence", {
  x <- canonical_writer_fixture()
  x <- x[!(x$record_id == 1L & x$field_order == 3L), ]

  diagnostics <- diagnose_canonical(x)

  expect_false(any(diagnostics$severity == "error"))
  expect_true("field_order_will_renumber" %in% diagnostics$code)
  expect_true("field_occurrence_stale" %in% diagnostics$code)
})

test_that("subfield deletion diagnoses renumbering and stale occurrence", {
  x <- canonical_writer_fixture()
  idx <- which(
    x$record_id == 1L &
      x$field_order == 4L &
      x$subfield_code == "a"
  )
  x <- x[-idx[[1L]], ]

  diagnostics <- diagnose_canonical(x)

  expect_false(any(diagnostics$severity == "error"))
  expect_true("subfield_order_will_renumber" %in% diagnostics$code)
  expect_true("subfield_occurrence_stale" %in% diagnostics$code)
})

test_that("occurrence counters are diagnostic rather than structural", {
  x <- canonical_writer_fixture()
  x$field_occurrence[x$field_type == "datafield"] <- NA_integer_
  x$subfield_occurrence[x$field_type == "datafield"] <- NA_integer_

  diagnostics <- diagnose_canonical(x)

  expect_false(any(diagnostics$severity == "error"))
  expect_true("field_occurrence_stale" %in% diagnostics$code)
  expect_true("subfield_occurrence_stale" %in% diagnostics$code)
})

test_that("non-applicable analytical coordinates are warnings", {
  x <- canonical_writer_fixture()
  x$subfield_order[[1L]] <- 99L
  x$subfield_occurrence[[1L]] <- 99L

  diagnostics <- diagnose_canonical(x)

  expect_false(any(diagnostics$severity == "error"))
  expect_true("non_applicable_subfield_order" %in% diagnostics$code)
  expect_true("non_applicable_subfield_occurrence" %in% diagnostics$code)
})

test_that("extra analysis columns do not make serialization unsafe", {
  x <- canonical_writer_fixture()
  x$selected <- TRUE

  expect_equal(nrow(diagnose_canonical(x)), 0L)
})

test_that("diagnostics do not impose MARC catalogue rules on tag/code strings", {
  x <- canonical_writer_fixture()
  idx <- which(x$record_id == 1L & x$field_order == 2L)
  x$tag[idx] <- "LOCAL-TAG"
  x$subfield_code[idx[[1L]]] <- "local-code"

  diagnostics <- diagnose_canonical(x)

  expect_equal(nrow(diagnostics), 0L)
})


test_that("controlfields cannot follow datafields in MARCXML field order", {
  x <- canonical_writer_fixture()

  x$field_order[x$record_id == 1L & x$field_order == 1L] <- 2L
  x$field_order[x$record_id == 1L & x$tag == "245"] <- 1L

  diagnostics <- diagnose_canonical(x)

  expect_true("field_type_order" %in% diagnostics$code)
  expect_true(any(diagnostics$severity == "error"))
})

test_that("structural NA coordinates are errors", {
  x <- canonical_writer_fixture()
  x$record_id[[1L]] <- NA_integer_
  expect_true("invalid_record_id" %in% diagnose_canonical(x)$code)

  x <- canonical_writer_fixture()
  x$field_order[[1L]] <- NA_integer_
  expect_true("invalid_field_order" %in% diagnose_canonical(x)$code)

  x <- canonical_writer_fixture()
  idx <- which(x$field_type == "datafield")[[1L]]
  x$subfield_order[[idx]] <- NA_integer_
  expect_true("invalid_subfield_order" %in% diagnose_canonical(x)$code)
})

test_that("field identity conflicts are diagnosed explicitly", {
  x <- canonical_writer_fixture()
  idx <- which(x$record_id == 1L & x$field_order == 2L)
  x$tag[[idx[[2L]]]] <- "246"
  expect_true("conflicting_tag" %in% diagnose_canonical(x)$code)

  x <- canonical_writer_fixture()
  idx <- which(x$record_id == 1L & x$field_order == 2L)
  row <- idx[[2L]]
  x$field_type[[row]] <- "controlfield"
  x$subfield_code[[row]] <- NA_character_
  x$ind1[[row]] <- NA_character_
  x$ind2[[row]] <- NA_character_
  expect_true("conflicting_field_type" %in% diagnose_canonical(x)$code)
})


test_that("XML 1.0 forbidden characters are structural errors", {
  x <- canonical_writer_fixture()
  idx <- which(x$record_id == 1L & x$field_order == 2L)[[1L]]
  x$value[[idx]] <- paste0("before", intToUtf8(1L), "after")

  diagnostics <- diagnose_canonical(x)

  expect_true("invalid_xml_character" %in% diagnostics$code)
  expect_true(any(diagnostics$severity == "error"))
  issue <- diagnostics[diagnostics$code == "invalid_xml_character", ]
  expect_identical(issue$record_id[[1L]], 1L)
  expect_identical(issue$field_order[[1L]], 2L)
  expect_identical(issue$subfield_order[[1L]], 1L)
})

test_that("XML 1.0 noncharacters are structural errors", {
  x <- canonical_writer_fixture()
  idx <- which(x$record_id == 1L & x$field_order == 2L)[[1L]]

  for (codepoint in c(0xFFFE, 0xFFFF)) {
    x$value[[idx]] <- intToUtf8(codepoint)
    expect_true(
      "invalid_xml_character" %in% diagnose_canonical(x)$code
    )
  }
})

test_that("XML metacharacters remain valid canonical text", {
  x <- canonical_writer_fixture()
  idx <- which(x$record_id == 1L & x$field_order == 2L)[[1L]]
  x$value[[idx]] <- "A & B < C > D"

  expect_false("invalid_xml_character" %in% diagnose_canonical(x)$code)
})
