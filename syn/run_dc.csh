#!/bin/csh
source /apps/design_environment.csh
cd `dirname $0`
dc_shell -f synthesis.script | tee synth_output_dc.log
