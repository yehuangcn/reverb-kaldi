#!/bin/bash

# Copyright 2012 Johns Hopkins University (Author: Daniel Povey).  Apache 2.0.
# This script, which will generally be called from other neural-net training
# scripts, extracts the training examples used to train the neural net (and also
# the validation examples used for diagnostics), and puts them in separate archives.

# Begin configuration section.
cmd=utils/run.pl
feat=
stage=0
splice_width=4 # meaning +- 4 frames on each side for second LDA
rand_prune=4.0 # Relates to a speedup we do for LDA.
within_class_factor=0.0001 # This affects the scaling of the transform rows...
# sorry for no explanation, you'll have to see the code.
transform_dir=     # If supplied, overrides alidir
num_feats=10000 # maximum number of feature files to use.  Beyond a certain point it just
# gets silly to use more data.
lda_dim=  # This defaults to no dimension reduction.
echo "$0 $@"  # Print the command line for logging

if [ -f path.sh ]; then . ./path.sh; fi
. parse_options.sh || exit 1;


if [ $# != 4 ]; then
    echo "Usage: steps/nnet2/get_lda.sh [opts] <data> <lang> <ali-dir> <exp-dir>"
    echo " e.g.: steps/nnet2/get_lda.sh data/train data/lang exp/tri3_ali exp/tri4_nnet"
    echo " As well as extracting the examples, this script will also do the LDA computation,"
    echo " if --est-lda=true (default:true)"
    echo ""
    echo "Main options (for others, see top of script file)"
    echo "  --config <config-file>                           # config file containing options"
    echo "  --cmd (utils/run.pl|utils/queue.pl <queue opts>) # how to run jobs."
    echo "  --splice-width <width|4>                         # Number of frames on each side to append for feature input"
    echo "                                                   # (note: we splice processed, typically 40-dimensional frames"
    echo "  --stage <stage|0>                                # Used to run a partially-completed training process from somewhere in"
    echo "                                                   # the middle."
    
    exit 1;
fi

data=$1
lang=$2
alidir=$3
dir=$4

# Check some files.
for f in $data/feats.scp $lang/L.fst $alidir/ali.1.gz $alidir/final.mdl $alidir/tree; do
    [ ! -f $f ] && echo "$0: no such file $f" && exit 1;
done

# Set some variables.
oov=`cat $lang/oov.int`
num_leaves=`gmm-info $alidir/final.mdl 2>/dev/null | awk '/number of pdfs/{print $NF}'` || exit 1;
silphonelist=`cat $lang/phones/silence.csl` || exit 1;

nj=`cat $alidir/num_jobs` || exit 1;  # number of jobs in alignment dir...
# in this dir we'll have just one job.
sdata=$data/split$nj
utils/split_data.sh $data $nj

mkdir -p $dir/log
echo $nj > $dir/num_jobs
cp $alidir/tree $dir

[ -z "$transform_dir" ] && transform_dir=$alidir

## Set up features.  Note: these are different from the normal features
## because we have one rspecifier that has the features for the entire
## training set, not separate ones for each batch.

# If we have more than $num_feats feature files (default: 10k),
# we use a random subset.  This won't affect the transform much, and will
# spare us an unnecessary pass over the data.  Probably 10k is
# way too much, but for small datasets this phase is quite fast.

N=$[$num_feats/$nj]

echo "${feat}" > $dir/feat_opt
feats=$(echo ${feat} | sed -s 's#SDATA_JOB#'${sdata}'/JOB#g')
echo "${feats}" >$dir/feat_string # keep track of feature type 


feats=$(echo $feats | sed 's#ark,s,cs:#ark,s,cs:utils/subset_scp.pl --quiet '"$N $sdata"'/JOB/feats.scp | #g' \
    | sed 's#scp:'$sdata'/JOB/feats.scp#scp:-#')
echo "$0: feature type is $feat_type"
echo "$0: feature is  ${feats}"


if [ -f $transform_dir/trans.1 ] && [ ${feat_type/lda/} != ${feat_type} ]; then
    echo "$0: using transforms from $transform_dir"
    feats="$feats transform-feats --utt2spk=ark:$sdata/JOB/utt2spk ark:$transform_dir/trans.JOB ark:- ark:- |"
fi
if [ -f $transform_dir/raw_trans.1 ] && [ ${feat_type/lda/} != ${feat_type} ]; then
    echo "$0: using raw-fMLLR transforms from $transform_dir"
    feats="$feats transform-feats --utt2spk=ark:$sdata/JOB/utt2spk ark:$transform_dir/raw_trans.JOB ark:- ark:- |"
fi


feats_one="$(echo "$feats" | sed s:JOB:1:g)"
feat_dim=$(feat-to-dim "$feats_one" -) || exit 1;
# by default: no dim reduction.
[ -z "$lda_dim" ] && lda_dim=$[$feat_dim*(1+2*($splice_width))]; 

if [ $stage -le 0 ]; then
    echo "$0: Accumulating LDA statistics."
    rm $dir/lda.*.acc 2>/dev/null # in case any left over from before.
    $cmd JOB=1:$nj $dir/log/lda_acc.JOB.log \
        ali-to-post "ark:gunzip -c $alidir/ali.JOB.gz|" ark:- \| \
        weight-silence-post 0.0 $silphonelist $alidir/final.mdl ark:- ark:- \| \
        acc-lda --rand-prune=$rand_prune $alidir/final.mdl "$feats splice-feats --left-context=$splice_width --right-context=$splice_width ark:- ark:- |" ark,s,cs:- \
        $dir/lda.JOB.acc || exit 1;
fi

echo $feat_dim > $dir/feat_dim
echo $lda_dim > $dir/lda_dim

if [ $stage -le 1 ]; then
    nnet-get-feature-transform --write-cholesky=$dir/cholesky.tpmat \
        --within-class-factor=$within_class_factor --dim=$lda_dim \
        $dir/lda.mat $dir/lda.*.acc \
        2>$dir/log/lda_est.log || exit 1;
    rm $dir/lda.*.acc
fi

echo "$0: Finished estimating LDA"
