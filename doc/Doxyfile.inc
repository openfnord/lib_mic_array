# This file provides overrides to the Doxyfile configuration

PROJECT_NAME           = lib_mic_array
PROJECT_BRIEF          = "PDM Mic Array library for the XMOS XS3 architecture"

INPUT                  = ../api ../../etc/vanilla  ../doc/src

PREDEFINED             = MA_C_API= C_API_START= C_API_END=

USE_MATHJAX            = YES
MATHJAX_FORMAT         = HTML-CSS
MATHJAX_RELPATH        = https://cdnjs.cloudflare.com/ajax/libs/mathjax/2.7.5/

# Make short MATHJAX sequences prettier
ALIASES += math{1}="@f$\1@f$"