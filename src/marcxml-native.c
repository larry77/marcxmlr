#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
#include <R_ext/Visibility.h>
#include <libxml/parser.h>
#include <libxml/xmlerror.h>
#include <libxml/tree.h>
#include <libxml/xmlreader.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* MARC-specific implementation of xmlrectr's native-engine design:
 * direct libxml2 traversal, count then allocate, and hashed occurrences.
 * No xml2 external-pointer ABI is used. Only owned record strings enter C.
 * NULL requests the unchanged R parser, including its diagnostics. */
typedef struct {
    SEXP texts, ids;
    xmlDocPtr *docs;
    R_xlen_t n;
    xmlParserCtxtPtr parser;
    xmlChar *text;
} parse_state;

typedef struct {
    const xmlChar *key;
    int scope, count;
} occurrence_slot;

static const char *column_names[] = {
    "record_id", "field_type", "tag", "subfield_code", "value",
    "field_order", "field_occurrence", "ind1", "ind2",
    "subfield_order", "subfield_occurrence"
};
static const SEXPTYPE column_types[] = {
    INTSXP, STRSXP, STRSXP, STRSXP, STRSXP, INTSXP,
    INTSXP, STRSXP, STRSXP, INTSXP, INTSXP
};

/* xml2 installs a global libxml2 error callback which can longjmp into R.
 * Override it on this owned parser only, so a declined fast path is silent
 * and the reference parser remains responsible for the public condition. */
#if LIBXML_VERSION >= 21200
static void quiet_error(void *context, const xmlError *error) {
#else
static void quiet_error(void *context, xmlError *error) {
#endif
    (void)context;
    (void)error;
}

static int named(xmlNodePtr node, const char *name) {
    return xmlStrEqual(node->name, BAD_CAST name);
}
static const xmlChar *namespace_uri(xmlNodePtr node) {
    return node->ns && node->ns->href ? node->ns->href : BAD_CAST "";
}
/* Complex/namespaced attributes go to xml2 so its attribute-selection and
 * entity semantics remain authoritative. Ordinary extra attributes are fine. */
static int simple_attributes(xmlNodePtr node) {
    for (xmlAttrPtr a = node->properties; a; a = a->next) {
        if (a->ns || (a->children && (a->children->type != XML_TEXT_NODE ||
                                    a->children->next))) return 0;
    }
    return 1;
}
static const xmlChar *attribute(xmlNodePtr node, const char *name) {
    for (xmlAttrPtr a = node->properties; a; a = a->next) {
        if (xmlStrEqual(a->name, BAD_CAST name)) {
            return a->children ? a->children->content : BAD_CAST "";
        }
    }
    return NULL;
}
static int nonempty(const xmlChar *s) { return s && s[0]; }
static int text_only(xmlNodePtr node) {
    for (xmlNodePtr c = node->children; c; c = c->next) {
        if (c->type != XML_TEXT_NODE && c->type != XML_CDATA_SECTION_NODE &&
            c->type != XML_COMMENT_NODE && c->type != XML_PI_NODE) return 0;
    }
    return 1;
}
static int ignorable(xmlNodePtr node) {
    return node->type == XML_TEXT_NODE || node->type == XML_CDATA_SECTION_NODE ||
           node->type == XML_COMMENT_NODE || node->type == XML_PI_NODE;
}

/* Validate the entire native subset before allocating/filling results.
 * Invalid or unfamiliar input is retried by the reference R implementation;
 * this preserves validation precedence and purrr's indexed errors. */
static int count_record_node(xmlNodePtr root, R_xlen_t *rows) {
    if (!root || !named(root, "record") || !simple_attributes(root)) return 0;
    const xmlChar *ns = namespace_uri(root);
    if (ns[0] && !xmlStrEqual(ns, BAD_CAST "http://www.loc.gov/MARC21/slim")) return 0;
    int fields = 0, leaders = 0;
    *rows = 0;
    for (xmlNodePtr f = root->children; f; f = f->next) {
        if (f->type != XML_ELEMENT_NODE) {
            if (!ignorable(f)) return 0;
            continue;
        }
        if (fields == INT_MAX) return 0;
        ++fields;
        if (!xmlStrEqual(namespace_uri(f), ns) || !simple_attributes(f)) return 0;
        if (named(f, "leader")) {
            if (fields != 1 || ++leaders != 1 || !text_only(f)) return 0;
            ++*rows;
        } else if (named(f, "controlfield")) {
            if (!nonempty(attribute(f, "tag")) || !text_only(f)) return 0;
            ++*rows;
        } else if (named(f, "datafield")) {
            if (!nonempty(attribute(f, "tag")) || !nonempty(attribute(f, "ind1")) ||
                !nonempty(attribute(f, "ind2"))) return 0;
            int subs = 0;
            for (xmlNodePtr s = f->children; s; s = s->next) {
                if (s->type != XML_ELEMENT_NODE) {
                    if (!ignorable(s)) return 0;
                    continue;
                }
                if (subs == INT_MAX) return 0;
                ++subs;
                if (!named(s, "subfield") || !xmlStrEqual(namespace_uri(s), ns) ||
                    !simple_attributes(s) || !nonempty(attribute(s, "code")) ||
                    !text_only(s)) return 0;
                ++*rows;
            }
            if (!subs) return 0;
        } else return 0;
        if (*rows > INT_MAX) return 0;
    }
    return leaders == 1;
}
static int count_record(xmlDocPtr doc, R_xlen_t *rows) {
    if (doc->intSubset || doc->extSubset) return 0;
    return count_record_node(xmlDocGetRootElement(doc), rows);
}

static size_t table_capacity(R_xlen_t n) {
    size_t cap = 16;
    if ((uint64_t)n > (uint64_t)SIZE_MAX / (2 * sizeof(occurrence_slot)))
        Rf_error("MARCXML occurrence table is too large.");
    while (cap < (size_t)n * 2) {
        if (cap > SIZE_MAX / 2) Rf_error("MARCXML occurrence table is too large.");
        cap *= 2;
    }
    if (cap > SIZE_MAX / sizeof(occurrence_slot))
        Rf_error("MARCXML occurrence table is too large.");
    return cap;
}
static int occurrence(occurrence_slot *slots, size_t cap,
                      const xmlChar *key, int scope) {
    uint64_t h = UINT64_C(14695981039346656037);
    for (const xmlChar *p = key; *p; ++p) {
        h ^= *p;
        h *= UINT64_C(1099511628211);
    }
    h ^= (uint32_t)scope;
    h *= UINT64_C(1099511628211);
    size_t i = (size_t)h & (cap - 1);
    while (slots[i].key) {
        if (slots[i].scope == scope && xmlStrEqual(slots[i].key, key))
            return ++slots[i].count;
        i = (i + 1) & (cap - 1);
    }
    slots[i].key = key;
    slots[i].scope = scope;
    return slots[i].count = 1;
}
static SEXP utf8(const xmlChar *s) {
    return Rf_mkCharCE(s ? (const char *)s : "", CE_UTF8);
}
static void set_text(parse_state *state, SEXP out, R_xlen_t row, xmlNodePtr node) {
    state->text = xmlNodeGetContent(node);
    SET_STRING_ELT(out, row, utf8(state->text));
    xmlFree(state->text);
    state->text = NULL;
}

static SEXP parse_body(void *data) {
    parse_state *state = (parse_state *)data;
    R_xlen_t total = 0, max_rows = 0;
    for (R_xlen_t i = 0; i < state->n; ++i) {
        R_CheckUserInterrupt();
        const char *text = Rf_translateCharUTF8(STRING_ELT(state->texts, i));
        size_t len = strlen(text);
        if (len > INT_MAX) return R_NilValue;
        state->parser = xmlNewParserCtxt();
        if (!state->parser) Rf_error("Could not allocate a MARCXML parser.");
#if LIBXML_VERSION >= 21300
        xmlCtxtSetErrorHandler(state->parser, quiet_error, NULL);
#else
        /* xmlCtxtSetErrorHandler() was added in libxml2 2.13.0.
         * On 2.12.x the structured callback already takes const xmlError *,
         * but the per-context SAX slot remains the compatible mechanism. */
        state->parser->sax->serror = quiet_error;
#endif
        /* NOBLANKS is xml2::read_xml()'s default; do not expand DTD entities. */
        state->docs[i] = xmlCtxtReadMemory(state->parser, text, (int)len,
            NULL, NULL, XML_PARSE_NOBLANKS | XML_PARSE_NONET |
            XML_PARSE_NOERROR | XML_PARSE_NOWARNING);
        const xmlError *last_error = xmlCtxtGetLastError(state->parser);
        int issue = last_error != NULL && last_error->code != XML_ERR_OK;
        xmlFreeParserCtxt(state->parser);
        state->parser = NULL;
        R_xlen_t rows;
        if (issue || !state->docs[i] || !count_record(state->docs[i], &rows))
            return R_NilValue;
        if (total > R_XLEN_T_MAX - rows) Rf_error("MARCXML result is too large.");
        total += rows;
        if (rows > max_rows) max_rows = rows;
    }

    SEXP result = PROTECT(Rf_allocVector(VECSXP, 11));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 11));
    SEXP cols[11];
    for (int c = 0; c < 11; ++c) {
        cols[c] = Rf_allocVector(column_types[c], total);
        SET_VECTOR_ELT(result, c, cols[c]);
        SET_STRING_ELT(names, c, Rf_mkChar(column_names[c]));
        for (R_xlen_t r = 0; r < total; ++r) {
            if (column_types[c] == INTSXP) INTEGER(cols[c])[r] = NA_INTEGER;
            else SET_STRING_ELT(cols[c], r, NA_STRING);
        }
    }
    Rf_setAttrib(result, R_NamesSymbol, names);
    size_t cap = table_capacity(max_rows);
    occurrence_slot *fields = (occurrence_slot *)R_alloc(cap, sizeof(occurrence_slot));
    occurrence_slot *subs = (occurrence_slot *)R_alloc(cap, sizeof(occurrence_slot));
    R_xlen_t row = 0;
    for (R_xlen_t i = 0; i < state->n; ++i) {
        R_CheckUserInterrupt();
        memset(fields, 0, cap * sizeof(occurrence_slot));
        memset(subs, 0, cap * sizeof(occurrence_slot));
        xmlNodePtr root = xmlDocGetRootElement(state->docs[i]);
        int order = -1;
        for (xmlNodePtr f = root->children; f; f = f->next) {
            if (f->type != XML_ELEMENT_NODE) continue;
            ++order;
            int leader = named(f, "leader");
            int control = named(f, "controlfield");
            const xmlChar *tag = leader ? BAD_CAST "LDR" : attribute(f, "tag");
            int occ = leader ? 1 : occurrence(fields, cap, tag, control);
            xmlNodePtr node = (leader || control) ? f : f->children;
            int suborder = 0;
            for (; node; node = node->next) {
                if (node->type != XML_ELEMENT_NODE) continue;
                if ((row & 4095) == 0) R_CheckUserInterrupt();
                INTEGER(cols[0])[row] = INTEGER(state->ids)[i];
                SET_STRING_ELT(cols[1], row, utf8(f->name));
                SET_STRING_ELT(cols[2], row, utf8(tag));
                set_text(state, cols[4], row, node);
                INTEGER(cols[5])[row] = order;
                INTEGER(cols[6])[row] = occ;
                if (!leader && !control) {
                    const xmlChar *code = attribute(node, "code");
                    SET_STRING_ELT(cols[3], row, utf8(code));
                    SET_STRING_ELT(cols[7], row, utf8(attribute(f, "ind1")));
                    SET_STRING_ELT(cols[8], row, utf8(attribute(f, "ind2")));
                    INTEGER(cols[9])[row] = ++suborder;
                    INTEGER(cols[10])[row] = occurrence(subs, cap, code, order);
                }
                ++row;
                if (leader || control) break;
            }
        }
        xmlFreeDoc(state->docs[i]);
        state->docs[i] = NULL;
    }
    UNPROTECT(2);
    return result;
}
static void cleanup(void *data) {
    parse_state *state = (parse_state *)data;
    if (state->parser) xmlFreeParserCtxt(state->parser);
    if (state->text) xmlFree(state->text);
    for (R_xlen_t i = 0; i < state->n; ++i) {
        if (state->docs[i]) xmlFreeDoc(state->docs[i]);
    }
}

typedef struct {
    xmlTextReaderPtr reader;
    int rc;
} marcxml_reader_state;

static int reader_named(xmlTextReaderPtr reader, const char *name) {
    const xmlChar *local = xmlTextReaderConstLocalName(reader);
    return local && xmlStrEqual(local, BAD_CAST name);
}

static int reader_namespace_ok(xmlTextReaderPtr reader) {
    const xmlChar *uri = xmlTextReaderConstNamespaceUri(reader);
    return !uri || !uri[0] ||
           xmlStrEqual(uri, BAD_CAST "http://www.loc.gov/MARC21/slim");
}

/* Scan the complete collection before creating the stateful reader.
 * Returning false declines the native streaming path; the unchanged R/XML
 * implementation then remains responsible for validation and diagnostics. */
static int validate_stream_collection(const char *path) {
    int options = XML_PARSE_NONET | XML_PARSE_NOERROR | XML_PARSE_NOWARNING;
    xmlTextReaderPtr reader = xmlReaderForFile(path, NULL, options);
    if (!reader) return 0;

    /* xml2 may have installed a global structured-error callback which
     * longjmps into R. Keep native fast-path validation silent so malformed
     * or unsupported input can decline cleanly to the reference R/XML path. */
    xmlTextReaderSetStructuredErrorHandler(
        reader,
        quiet_error,
        NULL
    );

    int root_seen = 0;
    int valid = 1;
    int rc = xmlTextReaderRead(reader);

    while (rc == 1 && valid) {
        int type = xmlTextReaderNodeType(reader);
        int depth = xmlTextReaderDepth(reader);

        if (type == XML_READER_TYPE_DOCUMENT_TYPE) {
            valid = 0;
            break;
        }

        if (type == XML_READER_TYPE_ELEMENT && depth == 0) {
            if (root_seen ||
                !reader_named(reader, "collection") ||
                !reader_namespace_ok(reader)) {
                valid = 0;
                break;
            }
            root_seen = 1;
        } else if (type == XML_READER_TYPE_ELEMENT && depth == 1) {
            if (!root_seen || !reader_named(reader, "record")) {
                valid = 0;
                break;
            }

            xmlNodePtr node = xmlTextReaderExpand(reader);
            R_xlen_t rows = 0;
            if (!node || !count_record_node(node, &rows)) {
                valid = 0;
                break;
            }
        }

        rc = xmlTextReaderRead(reader);
    }

    if (rc < 0 || !root_seen) valid = 0;

    xmlFreeTextReader(reader);
    return valid;
}

static SEXP reader_tag(void) {
    return Rf_install("marcxmlr_native_stream_reader");
}

static marcxml_reader_state *reader_state(SEXP ext) {
    if (TYPEOF(ext) != EXTPTRSXP ||
        R_ExternalPtrTag(ext) != reader_tag()) {
        Rf_error("Invalid native MARCXML reader.");
    }

    marcxml_reader_state *state =
        (marcxml_reader_state *)R_ExternalPtrAddr(ext);

    if (!state) Rf_error("Native MARCXML reader is closed.");
    return state;
}

static void reader_finalizer(SEXP ext) {
    if (TYPEOF(ext) != EXTPTRSXP) return;

    marcxml_reader_state *state =
        (marcxml_reader_state *)R_ExternalPtrAddr(ext);

    if (!state) return;

    if (state->reader) {
        xmlFreeTextReader(state->reader);
        state->reader = NULL;
    }

    free(state);
    R_ClearExternalPtr(ext);
}

SEXP C_marcxml_reader_open(SEXP path) {
    if (TYPEOF(path) != STRSXP ||
        XLENGTH(path) != 1 ||
        STRING_ELT(path, 0) == NA_STRING) {
        Rf_error("Invalid native MARCXML reader path.");
    }

    const char *file =
        Rf_translateCharUTF8(STRING_ELT(path, 0));

    if (!validate_stream_collection(file)) {
        return R_NilValue;
    }

    int options =
        XML_PARSE_NONET | XML_PARSE_NOERROR | XML_PARSE_NOWARNING;

    xmlTextReaderPtr reader =
        xmlReaderForFile(file, NULL, options);

    if (!reader) return R_NilValue;

    /* Keep this owned reader independent of xml2's global error callback.
     * Validation already succeeded, but this also prevents later reader
     * failures from escaping through the global callback. */
    xmlTextReaderSetStructuredErrorHandler(
        reader,
        quiet_error,
        NULL
    );

    marcxml_reader_state *state =
        (marcxml_reader_state *)calloc(
            1,
            sizeof(marcxml_reader_state)
        );

    if (!state) {
        xmlFreeTextReader(reader);
        Rf_error("Could not allocate a native MARCXML reader.");
    }

    state->reader = reader;
    state->rc = xmlTextReaderRead(reader);

    if (state->rc != 1) {
        xmlFreeTextReader(reader);
        free(state);
        return R_NilValue;
    }

    SEXP ext = PROTECT(
        R_MakeExternalPtr(
            state,
            reader_tag(),
            R_NilValue
        )
    );

    R_RegisterCFinalizerEx(
        ext,
        reader_finalizer,
        TRUE
    );

    UNPROTECT(1);
    return ext;
}

SEXP C_marcxml_reader_next(SEXP ext, SEXP maximum) {
    marcxml_reader_state *state = reader_state(ext);

    if (TYPEOF(maximum) != INTSXP ||
        XLENGTH(maximum) != 1 ||
        INTEGER(maximum)[0] < 1) {
        Rf_error("Invalid native MARCXML reader batch size.");
    }

    int limit = INTEGER(maximum)[0];
    SEXP out = PROTECT(Rf_allocVector(STRSXP, limit));
    int count = 0;

    while (state->rc == 1 && count < limit) {
        int type = xmlTextReaderNodeType(state->reader);
        int depth = xmlTextReaderDepth(state->reader);

        if (type == XML_READER_TYPE_ELEMENT && depth == 1) {
            if (!reader_named(state->reader, "record")) {
                UNPROTECT(1);
                Rf_error(
                    "Native MARCXML input changed after validation."
                );
            }

            xmlChar *outer =
                xmlTextReaderReadOuterXml(state->reader);

            if (!outer) {
                UNPROTECT(1);
                Rf_error(
                    "Could not serialize a MARCXML record."
                );
            }

            SET_STRING_ELT(
                out,
                count,
                utf8(outer)
            );
            xmlFree(outer);
            ++count;

            state->rc =
                xmlTextReaderNext(state->reader);

            continue;
        }

        state->rc =
            xmlTextReaderRead(state->reader);
    }

    if (state->rc < 0) {
        UNPROTECT(1);
        Rf_error(
            "Native MARCXML reader failed after validation."
        );
    }

    if (count == limit) {
        UNPROTECT(1);
        return out;
    }

    SEXP trimmed =
        PROTECT(Rf_lengthgets(out, count));

    UNPROTECT(2);
    return trimmed;
}

SEXP C_marcxml_reader_close(SEXP ext) {
    if (TYPEOF(ext) != EXTPTRSXP ||
        R_ExternalPtrTag(ext) != reader_tag()) {
        Rf_error("Invalid native MARCXML reader.");
    }

    reader_finalizer(ext);
    return R_NilValue;
}

SEXP C_marcxml_parse_records(SEXP texts, SEXP ids) {
    if (TYPEOF(texts) != STRSXP || TYPEOF(ids) != INTSXP ||
        XLENGTH(texts) != XLENGTH(ids)) Rf_error("Invalid native MARCXML inputs.");
    R_xlen_t n = XLENGTH(texts);
    for (R_xlen_t i = 0; i < n; ++i) {
        if (STRING_ELT(texts, i) == NA_STRING || INTEGER(ids)[i] == NA_INTEGER ||
            INTEGER(ids)[i] < 1) Rf_error("Invalid native MARCXML inputs.");
    }
    parse_state state = {texts, ids, NULL, n, NULL, NULL};
    state.docs = (xmlDocPtr *)R_alloc((size_t)(n ? n : 1), sizeof(xmlDocPtr));
    memset(state.docs, 0, (size_t)n * sizeof(xmlDocPtr));
    return R_ExecWithCleanup(parse_body, &state, cleanup, &state);
}
static const R_CallMethodDef call_methods[] = {
    {"C_marcxml_parse_records", (DL_FUNC)&C_marcxml_parse_records, 2},
    {"C_marcxml_reader_open", (DL_FUNC)&C_marcxml_reader_open, 1},
    {"C_marcxml_reader_next", (DL_FUNC)&C_marcxml_reader_next, 2},
    {"C_marcxml_reader_close", (DL_FUNC)&C_marcxml_reader_close, 1},
    {NULL, NULL, 0}
};
void attribute_visible R_init_marcxmlr(DllInfo *dll) {
    R_registerRoutines(dll, NULL, call_methods, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
    R_forceSymbols(dll, TRUE);
}
