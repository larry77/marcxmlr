# Windows libxml2 fallback adapted from r-lib/xml2 (MIT license).
# Use Rtools' libxml2 through pkg-config when available; this script runs only
# when Makevars.win needs a private bundle.
if (!file.exists("../windows/libxml2/include/libxml2/libxml")) {
  unlink("../windows", recursive = TRUE)

  url <- if (grepl("aarch", R.version$platform)) {
    "https://github.com/r-windows/bundles/releases/download/libxml2-2.11.5/libxml2-2.11.5-clang-aarch64.tar.xz"
  } else if (grepl("clang", Sys.getenv("R_COMPILED_BY"))) {
    "https://github.com/r-windows/bundles/releases/download/libxml2-2.11.5/libxml2-2.11.5-clang-x86_64.tar.xz"
  } else if (getRversion() >= "4.2") {
    "https://github.com/r-windows/bundles/releases/download/libxml2-2.11.5/libxml2-2.11.5-ucrt-x86_64.tar.xz"
  } else {
    # R 4.1 / Rtools40 fallback used by current xml2.
    "https://github.com/rwinlib/libxml2/archive/v2.10.3.tar.gz"
  }

  archive <- basename(url)
  download.file(url, archive, quiet = TRUE, mode = "wb")
  on.exit(unlink(archive), add = TRUE)
  dir.create("../windows", showWarnings = FALSE)
  untar(archive, exdir = "../windows", tar = "internal")

  entries <- list.files("../windows", full.names = TRUE)
  if (length(entries) != 1L || !dir.exists(entries)) {
    stop("Unexpected libxml2 bundle layout.", call. = FALSE)
  }
  if (!file.rename(entries, "../windows/libxml2")) {
    stop("Could not prepare the Windows libxml2 bundle.", call. = FALSE)
  }
}
