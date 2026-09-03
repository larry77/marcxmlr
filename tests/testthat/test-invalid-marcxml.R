test_that("an unsupported root or namespace is rejected", {
  wrong_root <- write_test_xml("<catalogue />")
  wrong_namespace <- write_test_xml(c(
    "<record xmlns=\"https://example.org/not-marc\">",
    "  <leader>00000nam a2200000 i 4500</leader>",
    "</record>"
  ))

  expect_error(read_marcxml(wrong_root), "expected a MARCXML")
  expect_error(read_marcxml(wrong_namespace), "uses namespace")
})

test_that("record structural errors are rejected", {
  missing_leader <- write_test_xml(c(
    "<record>",
    "  <controlfield tag=\"001\">x</controlfield>",
    "</record>"
  ))
  missing_tag <- write_test_xml(c(
    "<record>",
    "  <leader>00000nam a2200000 i 4500</leader>",
    "  <controlfield>x</controlfield>",
    "</record>"
  ))
  missing_indicator <- write_test_xml(c(
    "<record>",
    "  <leader>00000nam a2200000 i 4500</leader>",
    "  <datafield tag=\"245\" ind1=\"1\">",
    "    <subfield code=\"a\">x</subfield>",
    "  </datafield>",
    "</record>"
  ))
  missing_code <- write_test_xml(c(
    "<record>",
    "  <leader>00000nam a2200000 i 4500</leader>",
    "  <datafield tag=\"245\" ind1=\"1\" ind2=\"0\">",
    "    <subfield>x</subfield>",
    "  </datafield>",
    "</record>"
  ))
  empty_datafield <- write_test_xml(c(
    "<record>",
    "  <leader>00000nam a2200000 i 4500</leader>",
    "  <datafield tag=\"245\" ind1=\"1\" ind2=\"0\" />",
    "</record>"
  ))

  expect_error(read_marcxml(missing_leader), "must begin")
  expect_error(read_marcxml(missing_tag), "without a `tag`")
  expect_error(read_marcxml(missing_indicator), "without an `ind2`")
  expect_error(read_marcxml(missing_code), "without a `code`")
  expect_error(read_marcxml(empty_datafield), "without any `<subfield>`")
})

test_that("foreign and unexpectedly nested elements are rejected", {
  foreign <- write_test_xml(c(
    "<record xmlns=\"http://www.loc.gov/MARC21/slim\"",
    "        xmlns:x=\"https://example.org/foreign\">",
    "  <leader>00000nam a2200000 i 4500</leader>",
    "  <x:extra>not MARCXML</x:extra>",
    "</record>"
  ))
  nested <- write_test_xml(c(
    "<record>",
    "  <leader><value>not atomic</value></leader>",
    "</record>"
  ))

  expect_error(read_marcxml(foreign), "another namespace")
  expect_error(read_marcxml(nested), "invalid nested elements")
})
