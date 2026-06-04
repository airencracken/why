#!/bin/bash

# === Unicode non-printing / invisible characters valid as bash function names ===
#
# Key finding: bash's parser rejects $'\uXXXX'(){} syntax at parse time
# because the expansion result is not accepted as a function identifier.
# Workaround: assign raw bytes to a variable first, then use eval with
# the pre-expanded variable.
#
# The obfuscate.pl tool embeds raw bytes directly in output files.

declare -A CHARS=(
	[U+00AD_soft_hyphen]=$'\u00AD'
	[U+034F_combining_grapheme_joiner]=$'\u034F'
	[U+061C_arabic_letter_mark]=$'\u061C'
	[U+1680_ogham_space_mark]=$'\u1680'
	[U+180E_mongolian_vowel_separator]=$'\u180E'
	[U+200B_zero_width_space]=$'\u200B'
	[U+200C_zero_width_non_joiner]=$'\u200C'
	[U+200D_zero_width_joiner]=$'\u200D'
	[U+200E_left_to_right_mark]=$'\u200E'
	[U+200F_right_to_left_mark]=$'\u200F'
	[U+202A_ltr_embedding]=$'\u202A'
	[U+202B_rtl_embedding]=$'\u202B'
	[U+202C_pop_directional]=$'\u202C'
	[U+202D_ltr_override]=$'\u202D'
	[U+202E_rtl_override]=$'\u202E'
	[U+2060_word_joiner]=$'\u2060'
	[U+2061_function_application]=$'\u2061'
	[U+2062_invisible_times]=$'\u2062'
	[U+2063_invisible_separator]=$'\u2063'
	[U+2064_invisible_plus]=$'\u2064'
	[U+20E0_combining_enclosing_circle]=$'\u20E0'
	[U+3164_hangul_filler]=$'\u3164'
	[U+FE00_variation_selector_1]=$'\uFE00'
	[U+FEFF_bom_zwnbsp]=$'\uFEFF'
	[U+E0001_language_tag]=$'\U000E0001'
	[U+E0020_tag_space]=$'\U000E0020'
)

passed=0
failed=0

for label in "${!CHARS[@]}"; do
	name="${CHARS[$label]}"
	if eval "${name}() { :; }" 2>/dev/null; then
		if ${name} 2>/dev/null; then
			((passed++))
		else
			echo "FAIL (can't call): $label"
			((failed++))
		fi
	else
		echo "FAIL (can't define): $label"
		((failed++))
	fi
done

# Multi-character function names (mix of invisible chars)
m1=$'\u200B\u200C\u200D'
eval "${m1}() { :; }" 2>/dev/null && $m1 2>/dev/null \
	&& { echo "OK: multi-char ZWSP+ZWNJ+ZWJ"; ((passed++)); } \
	|| { echo "FAIL: multi-char ZWSP+ZWNJ+ZWJ"; ((failed++)); }

m2=$'\x01\u200B\x02\u2060\x03'
eval "${m2}() { :; }" 2>/dev/null && $m2 2>/dev/null \
	&& { echo "OK: mixed control+unicode"; ((passed++)); } \
	|| { echo "FAIL: mixed control+unicode"; ((failed++)); }

echo
echo "$passed passed, $failed failed"
