%{
/*
 * Copyright © 2010 Intel Corporation
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice (including the next
 * paragraph) shall be included in all copies or substantial portions of the
 * Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

#include <stdio.h>
#include <string.h>
#include <ctype.h>

#include "glcpp.h"
#include "glcpp-parse.h"

/* Flex annoyingly generates some functions without making them
 * static. Let's declare them here. */
int glcpp_get_column  (yyscan_t yyscanner);
void glcpp_set_column (int  column_no , yyscan_t yyscanner);

#define YY_NO_INPUT

#define YY_USER_ACTION                                          \
   do {                                                         \
      yylloc->first_column = yycolumn + 1;                      \
      yylloc->first_line = yylineno;                            \
      yycolumn += yyleng;                                       \
   } while(0);

#define YY_USER_INIT			\
	do {				\
		yylineno = 1;		\
		yycolumn = 1;		\
		yylloc->source = 0;	\
	} while(0)
%}

%option bison-bridge bison-locations reentrant noyywrap
%option extra-type="glcpp_parser_t *"
%option prefix="glcpp_"
%option stack
%option never-interactive

%x DONE COMMENT UNREACHABLE

SPACE		[[:space:]]
NONSPACE	[^[:space:]]
NEWLINE		[\n]
HSPACE		[ \t]
HASH		^{HSPACE}*#{HSPACE}*
IDENTIFIER	[_a-zA-Z][_a-zA-Z0-9]*
PUNCTUATION	[][(){}.&*~!/%<>^|;,=+-]
OTHER		[^][(){}.&*~!/%<>^|;,=#[:space:]+-]+

DIGITS			[0-9][0-9]*
DECIMAL_INTEGER		[1-9][0-9]*[uU]?
OCTAL_INTEGER		0[0-7]*[uU]?
HEXADECIMAL_INTEGER	0[xX][0-9a-fA-F]+[uU]?

%%

	/* Single-line comments */
"//"[^\n]* {
}

	/* Multi-line comments */
"/*"                    { yy_push_state(COMMENT, yyscanner); }
<COMMENT>[^*\n]*
<COMMENT>[^*\n]*\n      { yylineno++; yycolumn = 0; return NEWLINE; }
<COMMENT>"*"+[^*/\n]*
<COMMENT>"*"+[^*/\n]*\n { yylineno++; yycolumn = 0; return NEWLINE; }
<COMMENT>"*"+"/"        {
	yy_pop_state(yyscanner);
	if (yyextra->space_tokens)
		return SPACE;
}

{HASH}version {
	yylval->str = ralloc_strdup (yyextra, yytext);
	yyextra->space_tokens = 0;
	return HASH_VERSION;
}

	/* glcpp doesn't handle #extension, #version, or #pragma directives.
	 * Simply pass them through to the main compiler's lexer/parser. */
{HASH}(extension|pragma)[^\n]+ {
	yylval->str = ralloc_strdup (yyextra, yytext);
	yylineno++;
	yycolumn = 0;
	return OTHER;
}

{HASH}line{HSPACE}+{DIGITS}{HSPACE}+{DIGITS}{HSPACE}*$ {
	/* Eat characters until the first digit is
	 * encountered
	 */
	char *ptr = yytext;
	while (!isdigit(*ptr))
		ptr++;

	/* Subtract one from the line number because
	 * yylineno is zero-based instead of
	 * one-based.
	 */
	yylineno = strtol(ptr, &ptr, 0) - 1;
	yylloc->source = strtol(ptr, NULL, 0);
}

{HASH}line{HSPACE}+{DIGITS}{HSPACE}*$ {
	/* Eat characters until the first digit is
	 * encountered
	 */
	char *ptr = yytext;
	while (!isdigit(*ptr))
		ptr++;

	/* Subtract one from the line number because
	 * yylineno is zero-based instead of
	 * one-based.
	 */
	yylineno = strtol(ptr, &ptr, 0) - 1;
}

{HASH}ifdef/.*\n {
	yyextra->lexing_if = 1;
	yyextra->space_tokens = 0;
	return HASH_IFDEF;
}

{HASH}ifndef/.*\n {
	yyextra->lexing_if = 1;
	yyextra->space_tokens = 0;
	return HASH_IFNDEF;
}

{HASH}if/[^_a-zA-Z0-9].*\n {
	yyextra->lexing_if = 1;
	yyextra->space_tokens = 0;
	return HASH_IF;
}

{HASH}elif/.*\n {
	yyextra->lexing_if = 1;
	yyextra->space_tokens = 0;
	return HASH_ELIF;
}

{HASH}else/.*\n {
	yyextra->space_tokens = 0;
	return HASH_ELSE;
}

{HASH}endif/.*\n {
	yyextra->space_tokens = 0;
	return HASH_ENDIF;
}

	/* When skipping (due to an #if 0 or similar) consume anything
	 * up to a newline. We do this with less priority than any
	 * #if-related directive (#if, #elif, #else, #endif), but with
	 * more priority than any other directive or token to avoid
	 * any side-effects from skipped content.
	 *
	 * We use the lexing_if flag to avoid skipping any part of an
	 * if conditional expression. */
[^\n]+/\n {
	/* Since this rule always matches, YY_USER_ACTION gets called for it,
	 * wrongly incrementing yycolumn.  We undo that effect here. */
	yycolumn -= yyleng;
	if (yyextra->lexing_if ||
	    yyextra->skip_stack == NULL ||
	    yyextra->skip_stack->type == SKIP_NO_SKIP)
	{
		REJECT;
	}
}

{HASH}error.* {
	char *p;
	for (p = yytext; !isalpha(p[0]); p++); /* skip "  #   " */
	p += 5; /* skip "error" */
	glcpp_error(yylloc, yyextra, "#error%s", p);
}

{HASH}define{HSPACE}+/{IDENTIFIER}"(" {
	yyextra->space_tokens = 0;
	return HASH_DEFINE_FUNC;
}

{HASH}define {
	yyextra->space_tokens = 0;
	return HASH_DEFINE_OBJ;
}

{HASH}undef {
	yyextra->space_tokens = 0;
	return HASH_UNDEF;
}

{HASH} {
	yyextra->space_tokens = 0;
	return HASH;
}

{DECIMAL_INTEGER} {
	yylval->str = ralloc_strdup (yyextra, yytext);
	return INTEGER_STRING;
}

{OCTAL_INTEGER} {
	yylval->str = ralloc_strdup (yyextra, yytext);
	return INTEGER_STRING;
}

{HEXADECIMAL_INTEGER} {
	yylval->str = ralloc_strdup (yyextra, yytext);
	return INTEGER_STRING;
}

"<<"  {
	return LEFT_SHIFT;
}

">>" {
	return RIGHT_SHIFT;
}

"<=" {
	return LESS_OR_EQUAL;
}

">=" {
	return GREATER_OR_EQUAL;
}

"==" {
	return EQUAL;
}

"!=" {
	return NOT_EQUAL;
}

"&&" {
	return AND;
}

"||" {
	return OR;
}

"##" {
	return PASTE;
}

"defined" {
	return DEFINED;
}

{IDENTIFIER} {
	yylval->str = ralloc_strdup (yyextra, yytext);
	return IDENTIFIER;
}

{PUNCTUATION} {
	return yytext[0];
}

{OTHER}+ {
	yylval->str = ralloc_strdup (yyextra, yytext);
	return OTHER;
}

{HSPACE}+ {
	if (yyextra->space_tokens) {
		return SPACE;
	}
}

\n {
	yyextra->lexing_if = 0;
	yylineno++;
	yycolumn = 0;
	return NEWLINE;
}

	/* Handle missing newline at EOF. */
<INITIAL><<EOF>> {
	BEGIN DONE; /* Don't keep matching this rule forever. */
	yyextra->lexing_if = 0;
	return NEWLINE;
}

	/* We don't actually use the UNREACHABLE start condition. We
	only have this action here so that we can pretend to call some
	generated functions, (to avoid "defined but not used"
	warnings. */
<UNREACHABLE>. {
	unput('.');
	yy_top_state(yyextra);
}

%%

void
glcpp_lex_set_source_string(glcpp_parser_t *parser, const char *shader)
{
	yy_scan_string(shader, parser->scanner);
}
