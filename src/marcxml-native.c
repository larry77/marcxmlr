#include <R.h>
#include <Rinternals.h>
#include <R_ext/Rdynload.h>
#include <R_ext/Visibility.h>
#include <libxml/parser.h>
#include <libxml/xmlerror.h>
#include <libxml/tree.h>
#include <libxml/xmlreader.h>
#include <libxml/xmlwriter.h>
#include <limits.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* MARC-specific native engine using direct libxml2 traversal, count-then-
 * allocate output, and hashed occurrence counters. No xml2 external-pointer
 * ABI is used. Unsupported structures are declined to the R reference parser.
 * Parallel workers still receive only owned record strings. */
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
static void set_text(xmlChar **text, SEXP out, R_xlen_t row, xmlNodePtr node) {
    *text = xmlNodeGetContent(node);
    SET_STRING_ELT(out, row, utf8(*text));
    xmlFree(*text);
    *text = NULL;
}

/* Fill one already-validated MARCXML <record> directly into preallocated
 * canonical columns. The same semantic writer is used by both the retained
 * owned-string parser and the direct xmlTextReader path. */
static void write_record_node(
    xmlNodePtr root, int record_id, SEXP cols[11], R_xlen_t *row,
    occurrence_slot *fields, occurrence_slot *subs, size_t cap, xmlChar **text
) {
    memset(fields, 0, cap * sizeof(occurrence_slot));
    memset(subs, 0, cap * sizeof(occurrence_slot));
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
            if (((*row) & 4095) == 0) R_CheckUserInterrupt();
            INTEGER(cols[0])[*row] = record_id;
            SET_STRING_ELT(cols[1], *row, utf8(f->name));
            SET_STRING_ELT(cols[2], *row, utf8(tag));
            set_text(text, cols[4], *row, node);
            INTEGER(cols[5])[*row] = order;
            INTEGER(cols[6])[*row] = occ;
            if (!leader && !control) {
                const xmlChar *code = attribute(node, "code");
                SET_STRING_ELT(cols[3], *row, utf8(code));
                SET_STRING_ELT(cols[7], *row, utf8(attribute(f, "ind1")));
                SET_STRING_ELT(cols[8], *row, utf8(attribute(f, "ind2")));
                INTEGER(cols[9])[*row] = ++suborder;
                INTEGER(cols[10])[*row] = occurrence(subs, cap, code, order);
            }
            ++*row;
            if (leader || control) break;
        }
    }
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
        write_record_node(
            xmlDocGetRootElement(state->docs[i]), INTEGER(state->ids)[i],
            cols, &row, fields, subs, cap, &state->text
        );
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

/* -------------------------------------------------------------------------
 * Native planner
 * -------------------------------------------------------------------------
 * Read-only first pass: validate/count the native-supported subset and record
 * exact canonical row counts. No XML node pointer is retained after planning.
 */

enum {
    MARCXML_PLAN_READ = 0,
    MARCXML_PLAN_STREAM = 1
};

enum {
    MARCXML_ROOT_NONE = 0,
    MARCXML_ROOT_COLLECTION = 1,
    MARCXML_ROOT_RECORD = 2
};

typedef struct {
    char *path;
    int mode;
    int input_kind;
    int root_namespace_kind;
    R_xlen_t records_total;
    R_xlen_t records_selected;
    R_xlen_t rows_selected;
    R_xlen_t *rows_per_record;
    R_xlen_t rows_capacity;
} marcxml_plan_state;

static const char *plan_reason_string(int reason) {
    switch (reason) {
        case 1: return "xml_open";
        case 2: return "xml_parse";
        case 3: return "dtd";
        case 4: return "root";
        case 5: return "namespace";
        case 6: return "collection_child";
        case 7: return "record_structure";
        default: return "unknown";
    }
}

static char *copy_c_string(const char *value) {
    size_t n = strlen(value);
    if (n == SIZE_MAX) return NULL;

    char *out = (char *)malloc(n + 1);
    if (!out) return NULL;

    memcpy(out, value, n + 1);
    return out;
}

static void plan_state_free(marcxml_plan_state *plan) {
    if (!plan) return;
    free(plan->path);
    free(plan->rows_per_record);
    free(plan);
}

static int reader_namespace_kind(xmlTextReaderPtr reader) {
    const xmlChar *uri = xmlTextReaderConstNamespaceUri(reader);

    if (!uri || !uri[0]) return 0;

    if (xmlStrEqual(
            uri,
            BAD_CAST "http://www.loc.gov/MARC21/slim"
        )) {
        return 1;
    }

    return -1;
}

static int plan_append_rows(
    marcxml_plan_state *plan,
    R_xlen_t rows
) {
    if (plan->records_selected == R_XLEN_T_MAX) return 0;
    if (rows > R_XLEN_T_MAX - plan->rows_selected) return 0;

    R_xlen_t needed = plan->records_selected + 1;

    if (needed > plan->rows_capacity) {
        R_xlen_t new_capacity =
            plan->rows_capacity ? plan->rows_capacity : 1024;

        while (new_capacity < needed) {
            if (new_capacity > R_XLEN_T_MAX / 2) {
                new_capacity = needed;
                break;
            }
            new_capacity *= 2;
        }

        if ((uint64_t)new_capacity >
            (uint64_t)SIZE_MAX / sizeof(R_xlen_t)) {
            return 0;
        }

        R_xlen_t *new_rows = (R_xlen_t *)realloc(
            plan->rows_per_record,
            (size_t)new_capacity * sizeof(R_xlen_t)
        );

        if (!new_rows) return 0;

        plan->rows_per_record = new_rows;
        plan->rows_capacity = new_capacity;
    }

    plan->rows_per_record[plan->records_selected] = rows;
    plan->records_selected = needed;
    plan->rows_selected += rows;
    return 1;
}

static SEXP plan_tag(void) {
    return Rf_install("marcxmlr_native_plan");
}

static void plan_finalizer(SEXP ext) {
    if (TYPEOF(ext) != EXTPTRSXP) return;

    marcxml_plan_state *plan =
        (marcxml_plan_state *)R_ExternalPtrAddr(ext);

    if (!plan) return;

    plan_state_free(plan);
    R_ClearExternalPtr(ext);
}

static marcxml_plan_state *plan_state(SEXP ext) {
    if (TYPEOF(ext) != EXTPTRSXP ||
        R_ExternalPtrTag(ext) != plan_tag()) {
        Rf_error("Invalid native MARCXML plan.");
    }

    marcxml_plan_state *plan =
        (marcxml_plan_state *)R_ExternalPtrAddr(ext);

    if (!plan) {
        Rf_error("Native MARCXML plan is closed.");
    }

    return plan;
}

static SEXP plan_result(
    const char *status,
    const char *reason,
    SEXP plan
) {
    SEXP out = PROTECT(Rf_allocVector(VECSXP, 3));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 3));

    SET_STRING_ELT(names, 0, Rf_mkChar("status"));
    SET_STRING_ELT(names, 1, Rf_mkChar("reason"));
    SET_STRING_ELT(names, 2, Rf_mkChar("plan"));

    SET_VECTOR_ELT(out, 0, Rf_mkString(status));
    SET_VECTOR_ELT(
        out,
        1,
        reason ? Rf_mkString(reason) : Rf_ScalarString(NA_STRING)
    );
    SET_VECTOR_ELT(out, 2, plan);

    Rf_setAttrib(out, R_NamesSymbol, names);
    UNPROTECT(2);
    return out;
}

SEXP attribute_visible C_marcxml_plan_open(
    SEXP path,
    SEXP mode,
    SEXP n_max
) {
    if (TYPEOF(path) != STRSXP ||
        XLENGTH(path) != 1 ||
        STRING_ELT(path, 0) == NA_STRING ||
        TYPEOF(mode) != INTSXP ||
        XLENGTH(mode) != 1 ||
        INTEGER(mode)[0] < MARCXML_PLAN_READ ||
        INTEGER(mode)[0] > MARCXML_PLAN_STREAM ||
        TYPEOF(n_max) != REALSXP ||
        XLENGTH(n_max) != 1 ||
        ISNA(REAL(n_max)[0]) ||
        REAL(n_max)[0] < 0) {
        Rf_error("Invalid native MARCXML planner inputs.");
    }

    double limit = REAL(n_max)[0];
    if (R_FINITE(limit) && limit != floor(limit)) {
        Rf_error("Invalid native MARCXML planner n_max.");
    }

    const char *file =
        Rf_translateCharUTF8(STRING_ELT(path, 0));

    int options =
        XML_PARSE_NONET | XML_PARSE_NOERROR | XML_PARSE_NOWARNING;

    xmlTextReaderPtr reader =
        xmlReaderForFile(file, NULL, options);

    if (!reader) {
        return plan_result("decline", plan_reason_string(1), R_NilValue);
    }

    xmlTextReaderSetStructuredErrorHandler(reader, quiet_error, NULL);

    marcxml_plan_state *plan =
        (marcxml_plan_state *)calloc(
            1,
            sizeof(marcxml_plan_state)
        );

    if (!plan) {
        xmlFreeTextReader(reader);
        Rf_error("Could not allocate native MARCXML planner.");
    }

    plan->path = copy_c_string(file);
    if (!plan->path) {
        xmlFreeTextReader(reader);
        plan_state_free(plan);
        Rf_error("Could not allocate native MARCXML planner path.");
    }

    plan->mode = INTEGER(mode)[0];

    int root_seen = 0;
    int root_namespace = -2;
    int decline_reason = 0;
    int rc = xmlTextReaderRead(reader);

    while (rc == 1 && decline_reason == 0) {
        int type = xmlTextReaderNodeType(reader);
        int depth = xmlTextReaderDepth(reader);

        if (type == XML_READER_TYPE_DOCUMENT_TYPE) {
            decline_reason = 3;
            break;
        }

        if (type == XML_READER_TYPE_ELEMENT && depth == 0) {
            if (root_seen) {
                decline_reason = 4;
                break;
            }

            root_seen = 1;
            root_namespace = reader_namespace_kind(reader);

            if (root_namespace < 0) {
                decline_reason = 5;
                break;
            }

            plan->root_namespace_kind = root_namespace;

            if (reader_named(reader, "collection")) {
                plan->input_kind = MARCXML_ROOT_COLLECTION;
            } else if (
                plan->mode == MARCXML_PLAN_READ &&
                reader_named(reader, "record")
            ) {
                plan->input_kind = MARCXML_ROOT_RECORD;
            } else {
                decline_reason = 4;
                break;
            }

            if (plan->input_kind == MARCXML_ROOT_RECORD) {
                plan->records_total = 1;

                int selected =
                    !R_FINITE(limit) || limit >= 1.0;

                if (selected) {
                    xmlNodePtr node = xmlTextReaderExpand(reader);
                    R_xlen_t rows = 0;

                    if (!node) {
                        decline_reason = 2;
                        break;
                    }

                    if (!count_record_node(node, &rows)) {
                        decline_reason = 7;
                        break;
                    }

                    if (!plan_append_rows(plan, rows)) {
                        xmlFreeTextReader(reader);
                        plan_state_free(plan);
                        Rf_error(
                            "Could not extend native MARCXML planner."
                        );
                    }
                }

                rc = xmlTextReaderNext(reader);
                continue;
            }
        } else if (
            type == XML_READER_TYPE_ELEMENT &&
            depth == 1 &&
            plan->input_kind == MARCXML_ROOT_COLLECTION
        ) {
            if (!reader_named(reader, "record")) {
                decline_reason = 6;
                break;
            }

            int record_namespace =
                reader_namespace_kind(reader);

            if (record_namespace < 0 ||
                record_namespace != root_namespace) {
                decline_reason = 5;
                break;
            }

            if (plan->records_total == R_XLEN_T_MAX) {
                xmlFreeTextReader(reader);
                plan_state_free(plan);
                Rf_error(
                    "Native MARCXML planner record count is too large."
                );
            }

            plan->records_total += 1;

            int selected =
                plan->mode == MARCXML_PLAN_STREAM ||
                !R_FINITE(limit) ||
                (double)plan->records_total <= limit;

            if (selected) {
                xmlNodePtr node = xmlTextReaderExpand(reader);
                R_xlen_t rows = 0;

                if (!node) {
                    decline_reason = 2;
                    break;
                }

                if (!count_record_node(node, &rows)) {
                    decline_reason = 7;
                    break;
                }

                if (!plan_append_rows(plan, rows)) {
                    xmlFreeTextReader(reader);
                    plan_state_free(plan);
                    Rf_error(
                        "Could not extend native MARCXML planner."
                    );
                }
            }

            rc = xmlTextReaderNext(reader);
            continue;
        }

        rc = xmlTextReaderRead(reader);
    }

    if (rc < 0 && decline_reason == 0) {
        decline_reason = 2;
    }

    if (!root_seen && decline_reason == 0) {
        decline_reason = 4;
    }

    xmlFreeTextReader(reader);

    if (decline_reason != 0) {
        const char *reason =
            plan_reason_string(decline_reason);
        plan_state_free(plan);
        return plan_result("decline", reason, R_NilValue);
    }

    SEXP ext = PROTECT(
        R_MakeExternalPtr(
            plan,
            plan_tag(),
            R_NilValue
        )
    );

    R_RegisterCFinalizerEx(ext, plan_finalizer, TRUE);

    SEXP out = PROTECT(
        plan_result("supported", NULL, ext)
    );

    UNPROTECT(2);
    return out;
}

SEXP attribute_visible C_marcxml_plan_info(SEXP ext) {
    marcxml_plan_state *plan = plan_state(ext);

    SEXP out = PROTECT(Rf_allocVector(VECSXP, 7));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 7));
    SEXP rows = PROTECT(
        Rf_allocVector(
            REALSXP,
            plan->records_selected
        )
    );

    for (R_xlen_t i = 0; i < plan->records_selected; ++i) {
        REAL(rows)[i] =
            (double)plan->rows_per_record[i];
    }

    const char *mode_name =
        plan->mode == MARCXML_PLAN_READ ?
        "read" : "stream";

    const char *kind_name =
        plan->input_kind == MARCXML_ROOT_RECORD ?
        "record" : "collection";

    const char *name_values[] = {
        "path",
        "mode",
        "input_kind",
        "records_total",
        "records_selected",
        "rows_selected",
        "rows_per_record"
    };

    for (int i = 0; i < 7; ++i) {
        SET_STRING_ELT(
            names,
            i,
            Rf_mkChar(name_values[i])
        );
    }

    SET_VECTOR_ELT(out, 0, Rf_mkString(plan->path));
    SET_VECTOR_ELT(out, 1, Rf_mkString(mode_name));
    SET_VECTOR_ELT(out, 2, Rf_mkString(kind_name));
    SET_VECTOR_ELT(
        out,
        3,
        Rf_ScalarReal((double)plan->records_total)
    );
    SET_VECTOR_ELT(
        out,
        4,
        Rf_ScalarReal((double)plan->records_selected)
    );
    SET_VECTOR_ELT(
        out,
        5,
        Rf_ScalarReal((double)plan->rows_selected)
    );
    SET_VECTOR_ELT(out, 6, rows);

    Rf_setAttrib(out, R_NamesSymbol, names);

    UNPROTECT(3);
    return out;
}

SEXP attribute_visible C_marcxml_plan_close(SEXP ext) {
    if (TYPEOF(ext) != EXTPTRSXP ||
        R_ExternalPtrTag(ext) != plan_tag()) {
        Rf_error("Invalid native MARCXML plan.");
    }

    plan_finalizer(ext);
    return R_NilValue;
}


/* -------------------------------------------------------------------------
 * Direct single-record writer
 * -------------------------------------------------------------------------
 * Regression/development entry point. It consumes one record from a supported
 * plan and fills the canonical columns directly from xmlTextReaderExpand().
 */

typedef struct {
    marcxml_plan_state *plan;
    R_xlen_t record_index;
    int record_id;
    xmlTextReaderPtr reader;
    xmlChar *text;
} direct_record_state;

static void direct_record_cleanup(void *data) {
    direct_record_state *state = (direct_record_state *)data;

    if (state->text) {
        xmlFree(state->text);
        state->text = NULL;
    }

    if (state->reader) {
        xmlFreeTextReader(state->reader);
        state->reader = NULL;
    }
}

static SEXP direct_record_body(void *data) {
    direct_record_state *state = (direct_record_state *)data;
    marcxml_plan_state *plan = state->plan;

    int options =
        XML_PARSE_NONET | XML_PARSE_NOERROR | XML_PARSE_NOWARNING;

    state->reader =
        xmlReaderForFile(plan->path, NULL, options);

    if (!state->reader) {
        Rf_error(
            "Could not reopen MARCXML input for direct native writing."
        );
    }

    xmlTextReaderSetStructuredErrorHandler(
        state->reader,
        quiet_error,
        NULL
    );

    xmlNodePtr target = NULL;
    R_xlen_t seen = 0;
    int rc = xmlTextReaderRead(state->reader);

    while (rc == 1) {
        int type = xmlTextReaderNodeType(state->reader);
        int depth = xmlTextReaderDepth(state->reader);

        if (plan->input_kind == MARCXML_ROOT_RECORD) {
            if (type == XML_READER_TYPE_ELEMENT &&
                depth == 0 &&
                reader_named(state->reader, "record")) {
                seen = 1;
                if (state->record_index == 1) {
                    target = xmlTextReaderExpand(state->reader);
                    break;
                }
            }
        } else if (
            type == XML_READER_TYPE_ELEMENT &&
            depth == 1 &&
            reader_named(state->reader, "record")
        ) {
            ++seen;

            if (seen == state->record_index) {
                target = xmlTextReaderExpand(state->reader);
                break;
            }

            rc = xmlTextReaderNext(state->reader);
            continue;
        }

        rc = xmlTextReaderRead(state->reader);
    }

    if (rc < 0) {
        Rf_error(
            "MARCXML input changed or became unreadable after planning."
        );
    }

    if (!target) {
        Rf_error(
            "MARCXML input no longer matches the native plan."
        );
    }

    R_xlen_t actual_rows = 0;
    R_xlen_t expected_rows =
        plan->rows_per_record[state->record_index - 1];

    if (!count_record_node(target, &actual_rows) ||
        actual_rows != expected_rows) {
        Rf_error(
            "MARCXML record no longer matches the native plan."
        );
    }

    SEXP result = PROTECT(Rf_allocVector(VECSXP, 11));
    SEXP names = PROTECT(Rf_allocVector(STRSXP, 11));
    SEXP cols[11];

    for (int col = 0; col < 11; ++col) {
        cols[col] =
            Rf_allocVector(column_types[col], expected_rows);
        SET_VECTOR_ELT(result, col, cols[col]);
        SET_STRING_ELT(
            names,
            col,
            Rf_mkChar(column_names[col])
        );

        for (R_xlen_t row = 0; row < expected_rows; ++row) {
            if (column_types[col] == INTSXP) {
                INTEGER(cols[col])[row] = NA_INTEGER;
            } else {
                SET_STRING_ELT(cols[col], row, NA_STRING);
            }
        }
    }

    Rf_setAttrib(result, R_NamesSymbol, names);

    size_t cap = table_capacity(expected_rows);
    occurrence_slot *fields =
        (occurrence_slot *)R_alloc(
            cap,
            sizeof(occurrence_slot)
        );
    occurrence_slot *subs =
        (occurrence_slot *)R_alloc(
            cap,
            sizeof(occurrence_slot)
        );

    R_xlen_t row = 0;

    write_record_node(
        target,
        state->record_id,
        cols,
        &row,
        fields,
        subs,
        cap,
        &state->text
    );

    if (row != expected_rows) {
        UNPROTECT(2);
        Rf_error(
            "Direct MARCXML writer produced an unexpected row count."
        );
    }

    UNPROTECT(2);
    return result;
}

SEXP attribute_visible C_marcxml_plan_write_record(
    SEXP ext,
    SEXP record_index,
    SEXP record_id
) {
    marcxml_plan_state *plan = plan_state(ext);

    if (TYPEOF(record_index) != REALSXP ||
        XLENGTH(record_index) != 1 ||
        ISNA(REAL(record_index)[0]) ||
        !R_FINITE(REAL(record_index)[0]) ||
        REAL(record_index)[0] < 1 ||
        REAL(record_index)[0] != floor(REAL(record_index)[0]) ||
        REAL(record_index)[0] > (double)plan->records_selected ||
        TYPEOF(record_id) != INTSXP ||
        XLENGTH(record_id) != 1 ||
        INTEGER(record_id)[0] == NA_INTEGER ||
        INTEGER(record_id)[0] < 1) {
        Rf_error("Invalid direct MARCXML writer inputs.");
    }

    direct_record_state state;
    memset(&state, 0, sizeof(state));

    state.plan = plan;
    state.record_index =
        (R_xlen_t)REAL(record_index)[0];
    state.record_id = INTEGER(record_id)[0];

    return R_ExecWithCleanup(
        direct_record_body,
        &state,
        direct_record_cleanup,
        &state
    );
}



/* -------------------------------------------------------------------------
 * Direct canonical batch reader
 * -------------------------------------------------------------------------
 * Production second-pass engine. It copies the compact native plan, reopens
 * the XML once, and fills bounded canonical batches directly from expanded
 * record nodes. No record XML is serialized or reparsed.
 */

typedef struct {
    char *path;
    int input_kind;
    int root_namespace_kind;
    R_xlen_t records_selected;
    R_xlen_t *rows_per_record;
    R_xlen_t next_record;
    xmlTextReaderPtr reader;
    int rc;
    int root_seen;
    int failed;
    xmlChar *text;
} direct_batch_state;

static SEXP direct_batch_tag(void) {
    return Rf_install("marcxmlr_direct_batch_reader");
}

static void direct_batch_state_free(direct_batch_state *state) {
    if (!state) return;

    if (state->text) {
        xmlFree(state->text);
        state->text = NULL;
    }

    if (state->reader) {
        xmlFreeTextReader(state->reader);
        state->reader = NULL;
    }

    free(state->path);
    free(state->rows_per_record);
    free(state);
}

static void direct_batch_finalizer(SEXP ext) {
    if (TYPEOF(ext) != EXTPTRSXP) return;

    direct_batch_state *state =
        (direct_batch_state *)R_ExternalPtrAddr(ext);

    if (!state) return;

    direct_batch_state_free(state);
    R_ClearExternalPtr(ext);
}

static direct_batch_state *direct_batch_reader_state(SEXP ext) {
    if (TYPEOF(ext) != EXTPTRSXP ||
        R_ExternalPtrTag(ext) != direct_batch_tag()) {
        Rf_error("Invalid direct MARCXML batch reader.");
    }

    direct_batch_state *state =
        (direct_batch_state *)R_ExternalPtrAddr(ext);

    if (!state) {
        Rf_error("Direct MARCXML batch reader is closed.");
    }

    if (state->failed) {
        Rf_error(
            "Direct MARCXML batch reader is unusable after a previous failure."
        );
    }

    return state;
}

static void direct_batch_fail(
    direct_batch_state *state,
    const char *message
) {
    state->failed = 1;
    Rf_error("%s", message);
}

static int direct_batch_copy_plan(
    direct_batch_state *state,
    const marcxml_plan_state *plan
) {
    state->path = copy_c_string(plan->path);
    if (!state->path) return 0;

    state->input_kind = plan->input_kind;
    state->root_namespace_kind = plan->root_namespace_kind;
    state->records_selected = plan->records_selected;

    if (plan->records_selected == 0) return 1;

    if ((uint64_t)plan->records_selected >
        (uint64_t)SIZE_MAX / sizeof(R_xlen_t)) {
        return 0;
    }

    state->rows_per_record = (R_xlen_t *)malloc(
        (size_t)plan->records_selected * sizeof(R_xlen_t)
    );

    if (!state->rows_per_record) return 0;

    memcpy(
        state->rows_per_record,
        plan->rows_per_record,
        (size_t)plan->records_selected * sizeof(R_xlen_t)
    );

    return 1;
}

SEXP attribute_visible C_marcxml_direct_reader_open(SEXP plan_ext) {
    marcxml_plan_state *plan = plan_state(plan_ext);

    direct_batch_state *state =
        (direct_batch_state *)calloc(
            1,
            sizeof(direct_batch_state)
        );

    if (!state) {
        Rf_error("Could not allocate direct MARCXML batch reader.");
    }

    if (!direct_batch_copy_plan(state, plan)) {
        direct_batch_state_free(state);
        Rf_error("Could not copy native MARCXML plan.");
    }

    if (state->records_selected > 0) {
        int options =
            XML_PARSE_NONET | XML_PARSE_NOERROR | XML_PARSE_NOWARNING;

        state->reader =
            xmlReaderForFile(state->path, NULL, options);

        if (!state->reader) {
            direct_batch_state_free(state);
            Rf_error(
                "Could not reopen MARCXML input for direct batch writing."
            );
        }

        xmlTextReaderSetStructuredErrorHandler(
            state->reader,
            quiet_error,
            NULL
        );

        state->rc = xmlTextReaderRead(state->reader);

        if (state->rc != 1) {
            direct_batch_state_free(state);
            Rf_error(
                "MARCXML input became unreadable after planning."
            );
        }
    }

    SEXP ext = PROTECT(
        R_MakeExternalPtr(
            state,
            direct_batch_tag(),
            R_NilValue
        )
    );

    R_RegisterCFinalizerEx(
        ext,
        direct_batch_finalizer,
        TRUE
    );

    UNPROTECT(1);
    return ext;
}

SEXP attribute_visible C_marcxml_direct_reader_next(
    SEXP ext,
    SEXP maximum
) {
    direct_batch_state *state =
        direct_batch_reader_state(ext);

    if (TYPEOF(maximum) != INTSXP ||
        XLENGTH(maximum) != 1 ||
        INTEGER(maximum)[0] == NA_INTEGER ||
        INTEGER(maximum)[0] < 1) {
        Rf_error("Invalid direct MARCXML batch size.");
    }

    if (state->next_record >= state->records_selected) {
        return R_NilValue;
    }

    R_xlen_t remaining =
        state->records_selected - state->next_record;

    R_xlen_t record_limit =
        (R_xlen_t)INTEGER(maximum)[0];

    if (record_limit > remaining) {
        record_limit = remaining;
    }

    R_xlen_t total_rows = 0;
    R_xlen_t max_rows = 0;

    for (R_xlen_t i = 0; i < record_limit; ++i) {
        R_xlen_t rows =
            state->rows_per_record[state->next_record + i];

        if (rows > R_XLEN_T_MAX - total_rows) {
            Rf_error("Direct MARCXML batch is too large.");
        }

        total_rows += rows;
        if (rows > max_rows) max_rows = rows;
    }

    SEXP columns = PROTECT(
        Rf_allocVector(VECSXP, 11)
    );
    SEXP column_names_sexp = PROTECT(
        Rf_allocVector(STRSXP, 11)
    );
    SEXP cols[11];

    for (int col = 0; col < 11; ++col) {
        cols[col] =
            Rf_allocVector(column_types[col], total_rows);

        SET_VECTOR_ELT(columns, col, cols[col]);
        SET_STRING_ELT(
            column_names_sexp,
            col,
            Rf_mkChar(column_names[col])
        );

        if (column_types[col] == INTSXP) {
            for (R_xlen_t row = 0; row < total_rows; ++row) {
                INTEGER(cols[col])[row] = NA_INTEGER;
            }
        } else {
            for (R_xlen_t row = 0; row < total_rows; ++row) {
                SET_STRING_ELT(cols[col], row, NA_STRING);
            }
        }
    }

    Rf_setAttrib(
        columns,
        R_NamesSymbol,
        column_names_sexp
    );

    size_t cap = table_capacity(max_rows);
    occurrence_slot *fields =
        (occurrence_slot *)R_alloc(
            cap,
            sizeof(occurrence_slot)
        );
    occurrence_slot *subs =
        (occurrence_slot *)R_alloc(
            cap,
            sizeof(occurrence_slot)
        );

    R_xlen_t first_record =
        state->next_record + 1;
    R_xlen_t records_written = 0;
    R_xlen_t output_row = 0;

    while (state->rc == 1 &&
           records_written < record_limit) {
        int type = xmlTextReaderNodeType(state->reader);
        int depth = xmlTextReaderDepth(state->reader);

        if (type == XML_READER_TYPE_DOCUMENT_TYPE) {
            direct_batch_fail(
                state,
                "MARCXML input no longer matches the native plan."
            );
        }

        if (type == XML_READER_TYPE_ELEMENT && depth == 0) {
            if (state->root_seen) {
                direct_batch_fail(
                    state,
                    "MARCXML input no longer matches the native plan."
                );
            }

            int ns_kind =
                reader_namespace_kind(state->reader);

            if (ns_kind != state->root_namespace_kind) {
                direct_batch_fail(
                    state,
                    "MARCXML root namespace changed after planning."
                );
            }

            if (state->input_kind == MARCXML_ROOT_COLLECTION) {
                if (!reader_named(state->reader, "collection")) {
                    direct_batch_fail(
                        state,
                        "MARCXML root changed after planning."
                    );
                }

                state->root_seen = 1;
            } else {
                if (!reader_named(state->reader, "record")) {
                    direct_batch_fail(
                        state,
                        "MARCXML root changed after planning."
                    );
                }

                state->root_seen = 1;

                xmlNodePtr node =
                    xmlTextReaderExpand(state->reader);

                if (!node) {
                    direct_batch_fail(
                        state,
                        "Could not expand MARCXML record."
                    );
                }

                R_xlen_t expected_rows =
                    state->rows_per_record[state->next_record];
                R_xlen_t actual_rows = 0;

                if (!count_record_node(node, &actual_rows) ||
                    actual_rows != expected_rows) {
                    direct_batch_fail(
                        state,
                        "MARCXML record no longer matches the native plan."
                    );
                }

                R_xlen_t before = output_row;

                if (state->next_record + 1 > INT_MAX) {
                    direct_batch_fail(
                        state,
                        "MARCXML record_id exceeds integer capacity."
                    );
                }

                write_record_node(
                    node,
                    (int)(state->next_record + 1),
                    cols,
                    &output_row,
                    fields,
                    subs,
                    cap,
                    &state->text
                );

                if (output_row - before != expected_rows) {
                    direct_batch_fail(
                        state,
                        "Direct MARCXML writer produced an unexpected row count."
                    );
                }

                ++state->next_record;
                ++records_written;
                state->rc =
                    xmlTextReaderNext(state->reader);
                continue;
            }
        } else if (
            type == XML_READER_TYPE_ELEMENT &&
            depth == 1 &&
            state->input_kind == MARCXML_ROOT_COLLECTION
        ) {
            if (!state->root_seen ||
                !reader_named(state->reader, "record") ||
                reader_namespace_kind(state->reader) !=
                    state->root_namespace_kind) {
                direct_batch_fail(
                    state,
                    "MARCXML collection changed after planning."
                );
            }

            xmlNodePtr node =
                xmlTextReaderExpand(state->reader);

            if (!node) {
                direct_batch_fail(
                    state,
                    "Could not expand MARCXML record."
                );
            }

            R_xlen_t expected_rows =
                state->rows_per_record[state->next_record];
            R_xlen_t actual_rows = 0;

            if (!count_record_node(node, &actual_rows) ||
                actual_rows != expected_rows) {
                direct_batch_fail(
                    state,
                    "MARCXML record no longer matches the native plan."
                );
            }

            R_xlen_t before = output_row;

            if (state->next_record + 1 > INT_MAX) {
                direct_batch_fail(
                    state,
                    "MARCXML record_id exceeds integer capacity."
                );
            }

            write_record_node(
                node,
                (int)(state->next_record + 1),
                cols,
                &output_row,
                fields,
                subs,
                cap,
                &state->text
            );

            if (output_row - before != expected_rows) {
                direct_batch_fail(
                    state,
                    "Direct MARCXML writer produced an unexpected row count."
                );
            }

            ++state->next_record;
            ++records_written;

            state->rc =
                xmlTextReaderNext(state->reader);
            continue;
        }

        state->rc =
            xmlTextReaderRead(state->reader);
    }

    if (state->rc < 0) {
        direct_batch_fail(
            state,
            "MARCXML input became unreadable after planning."
        );
    }

    if (records_written != record_limit ||
        output_row != total_rows) {
        direct_batch_fail(
            state,
            "MARCXML input no longer matches the native plan."
        );
    }

    if (state->next_record == state->records_selected &&
        state->reader) {
        xmlFreeTextReader(state->reader);
        state->reader = NULL;
        state->rc = 0;
    }

    SEXP result = PROTECT(
        Rf_allocVector(VECSXP, 3)
    );
    SEXP result_names = PROTECT(
        Rf_allocVector(STRSXP, 3)
    );

    SET_STRING_ELT(
        result_names,
        0,
        Rf_mkChar("columns")
    );
    SET_STRING_ELT(
        result_names,
        1,
        Rf_mkChar("records")
    );
    SET_STRING_ELT(
        result_names,
        2,
        Rf_mkChar("first_record_id")
    );

    SET_VECTOR_ELT(result, 0, columns);
    SET_VECTOR_ELT(
        result,
        1,
        Rf_ScalarInteger((int)records_written)
    );
    SET_VECTOR_ELT(
        result,
        2,
        Rf_ScalarReal((double)first_record)
    );

    Rf_setAttrib(
        result,
        R_NamesSymbol,
        result_names
    );

    UNPROTECT(4);
    return result;
}

SEXP attribute_visible C_marcxml_direct_reader_close(SEXP ext) {
    if (TYPEOF(ext) != EXTPTRSXP ||
        R_ExternalPtrTag(ext) != direct_batch_tag()) {
        Rf_error("Invalid direct MARCXML batch reader.");
    }

    direct_batch_finalizer(ext);
    return R_NilValue;
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


/* Serialize one already-diagnosed, already-ordered canonical shard directly
 * with libxml2's streaming xmlTextWriter API. R remains responsible for
 * diagnostics, shard selection, staging/rollback, and public conditions. */
static int writer_same_utf8(SEXP x, R_xlen_t i, R_xlen_t j) {
    if (STRING_ELT(x, i) == NA_STRING || STRING_ELT(x, j) == NA_STRING)
        return 0;
    return strcmp(
        Rf_translateCharUTF8(STRING_ELT(x, i)),
        Rf_translateCharUTF8(STRING_ELT(x, j))
    ) == 0;
}

static void validate_writer_columns(SEXP columns) {
    static const SEXPTYPE expected[] = {
        INTSXP, STRSXP, STRSXP, STRSXP, STRSXP,
        INTSXP, STRSXP, STRSXP, INTSXP
    };

    if (TYPEOF(columns) != VECSXP || XLENGTH(columns) != 9)
        Rf_error("Invalid native MARCXML writer columns.");

    R_xlen_t n = XLENGTH(VECTOR_ELT(columns, 0));

    for (int j = 0; j < 9; ++j) {
        SEXP column = VECTOR_ELT(columns, j);
        if (TYPEOF(column) != expected[j] || XLENGTH(column) != n)
            Rf_error("Invalid native MARCXML writer columns.");
    }

    SEXP record_id = VECTOR_ELT(columns, 0);
    SEXP field_type = VECTOR_ELT(columns, 1);
    SEXP tag = VECTOR_ELT(columns, 2);
    SEXP subfield_code = VECTOR_ELT(columns, 3);
    SEXP value = VECTOR_ELT(columns, 4);
    SEXP field_order = VECTOR_ELT(columns, 5);
    SEXP ind1 = VECTOR_ELT(columns, 6);
    SEXP ind2 = VECTOR_ELT(columns, 7);
    SEXP subfield_order = VECTOR_ELT(columns, 8);

    int previous_record = 0;
    int previous_field = -1;
    int previous_subfield = 0;
    int seen_datafield = 0;

    for (R_xlen_t i = 0; i < n; ++i) {
        int rid = INTEGER(record_id)[i];
        int order = INTEGER(field_order)[i];

        if (rid == NA_INTEGER || rid < 1 ||
            order == NA_INTEGER || order < 0 ||
            STRING_ELT(field_type, i) == NA_STRING ||
            STRING_ELT(tag, i) == NA_STRING ||
            STRING_ELT(value, i) == NA_STRING) {
            Rf_error("Invalid native MARCXML writer row.");
        }

        const char *type =
            Rf_translateCharUTF8(STRING_ELT(field_type, i));
        int leader = strcmp(type, "leader") == 0;
        int control = strcmp(type, "controlfield") == 0;
        int data = strcmp(type, "datafield") == 0;

        if (!leader && !control && !data)
            Rf_error("Invalid native MARCXML writer field type.");

        int new_record = (i == 0 || rid != previous_record);

        if (new_record) {
            if (i > 0 && rid <= previous_record)
                Rf_error("Native MARCXML writer rows are not record-ordered.");
            if (!leader || order != 0)
                Rf_error("Native MARCXML writer record does not begin with its leader.");

            previous_record = rid;
            previous_field = 0;
            previous_subfield = 0;
            seen_datafield = 0;
        } else {
            if (leader)
                Rf_error("Native MARCXML writer encountered a misplaced leader.");
            if (order < previous_field)
                Rf_error("Native MARCXML writer rows are not field-ordered.");

            if (order == previous_field) {
                if (!data || i == 0 ||
                    !writer_same_utf8(field_type, i, i - 1) ||
                    !writer_same_utf8(tag, i, i - 1) ||
                    !writer_same_utf8(ind1, i, i - 1) ||
                    !writer_same_utf8(ind2, i, i - 1)) {
                    Rf_error("Native MARCXML writer field rows are inconsistent.");
                }
            } else {
                previous_field = order;
                previous_subfield = 0;
            }
        }

        if (control && seen_datafield)
            Rf_error("Native MARCXML writer encountered a controlfield after a datafield.");

        if (data) {
            int suborder = INTEGER(subfield_order)[i];
            if (STRING_ELT(subfield_code, i) == NA_STRING ||
                STRING_ELT(ind1, i) == NA_STRING ||
                STRING_ELT(ind2, i) == NA_STRING ||
                suborder == NA_INTEGER || suborder < 1 ||
                suborder <= previous_subfield) {
                Rf_error("Invalid native MARCXML writer datafield row.");
            }
            previous_subfield = suborder;
            seen_datafield = 1;
        } else {
            previous_subfield = 0;
        }
    }
}

SEXP C_marcxml_write_collection(SEXP columns, SEXP path, SEXP pretty) {
    validate_writer_columns(columns);

    if (TYPEOF(path) != STRSXP || XLENGTH(path) != 1 ||
        STRING_ELT(path, 0) == NA_STRING ||
        TYPEOF(pretty) != LGLSXP || XLENGTH(pretty) != 1 ||
        LOGICAL(pretty)[0] == NA_LOGICAL) {
        Rf_error("Invalid native MARCXML writer arguments.");
    }

    const char *file = Rf_translateCharUTF8(STRING_ELT(path, 0));
    xmlTextWriterPtr writer = xmlNewTextWriterFilename(file, 0);
    if (!writer)
        Rf_error("Could not create native MARCXML output writer.");

    const char *failure = NULL;
    int indent = LOGICAL(pretty)[0] ? 1 : 0;

#define WRITER_STEP(call, message) do { \
    if ((call) < 0) { failure = (message); goto writer_fail; } \
} while (0)

    WRITER_STEP(
        xmlTextWriterSetIndent(writer, indent),
        "Could not configure native MARCXML indentation."
    );
    if (indent) {
        WRITER_STEP(
            xmlTextWriterSetIndentString(writer, BAD_CAST "  "),
            "Could not configure native MARCXML indentation."
        );
    }

    WRITER_STEP(
        xmlTextWriterStartDocument(writer, "1.0", "UTF-8", NULL),
        "Could not start native MARCXML document."
    );
    WRITER_STEP(
        xmlTextWriterStartElementNS(
            writer,
            NULL,
            BAD_CAST "collection",
            BAD_CAST "http://www.loc.gov/MARC21/slim"
        ),
        "Could not start MARCXML collection."
    );

    SEXP record_id = VECTOR_ELT(columns, 0);
    SEXP field_type = VECTOR_ELT(columns, 1);
    SEXP tag = VECTOR_ELT(columns, 2);
    SEXP subfield_code = VECTOR_ELT(columns, 3);
    SEXP value = VECTOR_ELT(columns, 4);
    SEXP field_order = VECTOR_ELT(columns, 5);
    SEXP ind1 = VECTOR_ELT(columns, 6);
    SEXP ind2 = VECTOR_ELT(columns, 7);
    R_xlen_t n = XLENGTH(record_id);

    int current_record = 0;
    int current_field = -1;
    int record_open = 0;
    int datafield_open = 0;

    for (R_xlen_t i = 0; i < n; ++i) {
        if ((i & 4095) == 0) R_CheckUserInterrupt();

        int rid = INTEGER(record_id)[i];
        int order = INTEGER(field_order)[i];
        const char *type =
            Rf_translateCharUTF8(STRING_ELT(field_type, i));
        int new_record = !record_open || rid != current_record;
        int new_field = new_record || order != current_field;

        if (new_record) {
            if (datafield_open) {
                WRITER_STEP(
                    xmlTextWriterEndElement(writer),
                    "Could not close MARCXML datafield."
                );
                datafield_open = 0;
            }
            if (record_open) {
                WRITER_STEP(
                    xmlTextWriterEndElement(writer),
                    "Could not close MARCXML record."
                );
            }
            WRITER_STEP(
                xmlTextWriterStartElement(writer, BAD_CAST "record"),
                "Could not start MARCXML record."
            );
            record_open = 1;
            current_record = rid;
            current_field = -1;
            new_field = 1;
        }

        if (new_field && datafield_open) {
            WRITER_STEP(
                xmlTextWriterEndElement(writer),
                "Could not close MARCXML datafield."
            );
            datafield_open = 0;
        }

        if (new_field) {
            current_field = order;

            if (strcmp(type, "leader") == 0) {
                WRITER_STEP(
                    xmlTextWriterWriteElement(
                        writer,
                        BAD_CAST "leader",
                        BAD_CAST Rf_translateCharUTF8(STRING_ELT(value, i))
                    ),
                    "Could not write MARCXML leader."
                );
                continue;
            }

            if (strcmp(type, "controlfield") == 0) {
                WRITER_STEP(
                    xmlTextWriterStartElement(writer, BAD_CAST "controlfield"),
                    "Could not start MARCXML controlfield."
                );
                WRITER_STEP(
                    xmlTextWriterWriteAttribute(
                        writer,
                        BAD_CAST "tag",
                        BAD_CAST Rf_translateCharUTF8(STRING_ELT(tag, i))
                    ),
                    "Could not write MARCXML controlfield tag."
                );
                WRITER_STEP(
                    xmlTextWriterWriteString(
                        writer,
                        BAD_CAST Rf_translateCharUTF8(STRING_ELT(value, i))
                    ),
                    "Could not write MARCXML controlfield value."
                );
                WRITER_STEP(
                    xmlTextWriterEndElement(writer),
                    "Could not close MARCXML controlfield."
                );
                continue;
            }

            WRITER_STEP(
                xmlTextWriterStartElement(writer, BAD_CAST "datafield"),
                "Could not start MARCXML datafield."
            );
            datafield_open = 1;
            WRITER_STEP(
                xmlTextWriterWriteAttribute(
                    writer,
                    BAD_CAST "tag",
                    BAD_CAST Rf_translateCharUTF8(STRING_ELT(tag, i))
                ),
                "Could not write MARCXML datafield tag."
            );
            WRITER_STEP(
                xmlTextWriterWriteAttribute(
                    writer,
                    BAD_CAST "ind1",
                    BAD_CAST Rf_translateCharUTF8(STRING_ELT(ind1, i))
                ),
                "Could not write MARCXML ind1."
            );
            WRITER_STEP(
                xmlTextWriterWriteAttribute(
                    writer,
                    BAD_CAST "ind2",
                    BAD_CAST Rf_translateCharUTF8(STRING_ELT(ind2, i))
                ),
                "Could not write MARCXML ind2."
            );
        }

        if (strcmp(type, "datafield") == 0) {
            WRITER_STEP(
                xmlTextWriterStartElement(writer, BAD_CAST "subfield"),
                "Could not start MARCXML subfield."
            );
            WRITER_STEP(
                xmlTextWriterWriteAttribute(
                    writer,
                    BAD_CAST "code",
                    BAD_CAST Rf_translateCharUTF8(STRING_ELT(subfield_code, i))
                ),
                "Could not write MARCXML subfield code."
            );
            WRITER_STEP(
                xmlTextWriterWriteString(
                    writer,
                    BAD_CAST Rf_translateCharUTF8(STRING_ELT(value, i))
                ),
                "Could not write MARCXML subfield value."
            );
            WRITER_STEP(
                xmlTextWriterEndElement(writer),
                "Could not close MARCXML subfield."
            );
        }
    }

    if (datafield_open) {
        WRITER_STEP(
            xmlTextWriterEndElement(writer),
            "Could not close MARCXML datafield."
        );
    }
    if (record_open) {
        WRITER_STEP(
            xmlTextWriterEndElement(writer),
            "Could not close MARCXML record."
        );
    }
    WRITER_STEP(
        xmlTextWriterEndElement(writer),
        "Could not close MARCXML collection."
    );
    WRITER_STEP(
        xmlTextWriterEndDocument(writer),
        "Could not finish native MARCXML document."
    );
    WRITER_STEP(
        xmlTextWriterFlush(writer),
        "Could not flush native MARCXML document."
    );

    xmlFreeTextWriter(writer);
#undef WRITER_STEP
    return R_NilValue;

writer_fail:
    xmlFreeTextWriter(writer);
#undef WRITER_STEP
    Rf_error("%s", failure ? failure : "Native MARCXML writer failed.");
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
    {"C_marcxml_plan_open", (DL_FUNC)&C_marcxml_plan_open, 3},
    {"C_marcxml_plan_info", (DL_FUNC)&C_marcxml_plan_info, 1},
    {"C_marcxml_plan_close", (DL_FUNC)&C_marcxml_plan_close, 1},
    {"C_marcxml_plan_write_record", (DL_FUNC)&C_marcxml_plan_write_record, 3},
    {"C_marcxml_direct_reader_open", (DL_FUNC)&C_marcxml_direct_reader_open, 1},
    {"C_marcxml_direct_reader_next", (DL_FUNC)&C_marcxml_direct_reader_next, 2},
    {"C_marcxml_direct_reader_close", (DL_FUNC)&C_marcxml_direct_reader_close, 1},
    {"C_marcxml_parse_records", (DL_FUNC)&C_marcxml_parse_records, 2},
    {"C_marcxml_reader_open", (DL_FUNC)&C_marcxml_reader_open, 1},
    {"C_marcxml_reader_next", (DL_FUNC)&C_marcxml_reader_next, 2},
    {"C_marcxml_reader_close", (DL_FUNC)&C_marcxml_reader_close, 1},
    {"C_marcxml_write_collection", (DL_FUNC)&C_marcxml_write_collection, 3},
    {NULL, NULL, 0}
};
void attribute_visible R_init_marcxmlr(DllInfo *dll) {
    R_registerRoutines(dll, NULL, call_methods, NULL, NULL);
    R_useDynamicSymbols(dll, FALSE);
    R_forceSymbols(dll, TRUE);
}
