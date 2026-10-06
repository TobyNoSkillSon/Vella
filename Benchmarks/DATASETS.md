# Audio sources and terms

All recordings are fetched from pinned upstreams, never redistributed by this repository. Licences below reproduce the frozen source audit; the linked source terms govern audio and references. A dataset licence is not a grant of every underlying recording right. The manifests preserve attribution, original reference text, revision, origin/row/time/channel and SHA-256 identity. Treat Polish TEDx references as CC BY-NC-ND 4.0; do not relicense them under the application MIT licence. CC BY-SA sources retain their share-alike terms.

No recording enters Git or a Vella release asset. This also keeps the clone light. Before proposing future bundled audio, check the actual upstream licence and original rights and obtain maintainer approval; the prior audit alone is not clearance.

| Source | Licence in frozen audit | Full extracted MB | Quick extracted MB | Audio policy |
|---|---|---:|---:|---|
| `aishell4` | CC BY-SA 4.0 | 3.033 | 0.386 | Fetch pinned upstream; prior audit permits redistribution |
| `ami` | CC BY 4.0 | 4.911 | 0.228 | Fetch pinned upstream; prior audit permits redistribution |
| `apptek` | CC BY-SA 4.0 | 18.326 | 0.000 | Fetch pinned upstream; prior audit permits redistribution |
| `dipco` | CDLA-Permissive-1.0 | 7.904 | 0.060 | Fetch pinned upstream; prior audit permits redistribution |
| `earnings25` | CC BY 4.0 transcripts/metadata; recording redistribution unclear | 18.679 | 0.000 | Fetch pinned upstream; do not redistribute audio |
| `edacc` | CC BY-SA 4.0 | 18.842 | 2.764 | Fetch pinned upstream; prior audit permits redistribution |
| `fleurs` | CC BY 4.0 | 15.833 | 2.603 | Fetch pinned upstream; prior audit permits redistribution |
| `hike` | Apache-2.0 | 3.401 | 0.473 | Fetch pinned upstream; prior audit permits redistribution |
| `klang` | CC BY 4.0 | 4.948 | 0.660 | Fetch pinned upstream; prior audit permits redistribution |
| `librispeech-pc` | CC BY 4.0 | 5.259 | 1.534 | Fetch pinned upstream; prior audit permits redistribution |
| `mediaspeech` | CC BY 4.0 dataset; original videos retain owners’ copyright | 21.590 | 3.143 | Fetch pinned upstream; do not redistribute audio |
| `mls` | CC BY 4.0 | 2.922 | 0.439 | Fetch pinned upstream; prior audit permits redistribution |
| `monsoon` | CC BY 4.0 | 13.851 | 2.094 | Fetch pinned upstream; prior audit permits redistribution |
| `muscat` | CC BY 4.0 | 10.350 | 1.490 | Fetch pinned upstream; prior audit permits redistribution |
| `notsofar` | CC BY 4.0 | 17.181 | 0.104 | Fetch pinned upstream; prior audit permits redistribution |
| `polish-tedx` | CC BY-NC-ND 4.0 | 7.042 | 0.936 | Fetch pinned upstream; do not redistribute audio |
| `rev-earnings` | CC BY-SA 4.0 text only; audio rights unclear | 17.141 | 3.383 | Fetch pinned upstream; do not redistribute audio |
| `rev16` | CC BY-SA 4.0 text only; podcast audio rights unclear | 23.347 | 0.000 | Fetch pinned upstream; do not redistribute audio |
| `zeroth` | CC BY 4.0 | 3.434 | 0.520 | Fetch pinned upstream; prior audit permits redistribution |

Sizes are measured compressed FLAC bytes, decimal MB; container downloads are larger. Quick and full share files. PCM verification is mandatory even when FLAC byte encoding changes.

## aishell4

AISHELL-4, Beijing Shell Shell Technology Co., Ltd.; OpenSLR SLR111; utterance files redistributed by shenyunhang/AISHELL-4.

Source: https://www.openslr.org/111/
Licence: https://www.openslr.org/111/
Pinned upstream "revision": `df062e4993eeb9873605f8c74d6fac1db0560799`

## ami

AMI Corpus, University of Edinburgh; official AMI download, CC BY 4.0.

Source: https://groups.inf.ed.ac.uk/ami/download/
Licence: https://groups.inf.ed.ac.uk/ami/download/
Pinned upstream "revision": `manual-v1.6.2 SHA256:b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d; ES2004a.Array1-01.wav SHA256:6936edac5d0904fc5c4ab175546c5cc5366601fdc1b1e5183a6ea2c10f05d150`

## apptek

AppTek, Call-Center Dialogues (2026); role-played customer-service recordings.

Source: https://huggingface.co/datasets/apptek-com/apptek_callcenter_dialogues
Licence: https://huggingface.co/datasets/apptek-com/apptek_callcenter_dialogues/blob/b98967d9946f7f59f58d08624a2a00fe98fe0219/README.md
Pinned upstream "revision": `b98967d9946f7f59f58d08624a2a00fe98fe0219`

## dipco

DiPCo corpus, Dinner Party Corpus; huckiyang/DiPCo mirror.

Source: https://huggingface.co/datasets/huckiyang/DiPCo
Licence: https://huggingface.co/datasets/huckiyang/DiPCo/blob/e2b29d3d0d88692c744feb15e290f7316b68014e/README.md
Pinned upstream "revision": `e2b29d3d0d88692c744feb15e290f7316b68014e`

## earnings25

Florence Jiang et al., Earnings25 (2026), Zenodo DOI 10.5281/zenodo.18762167.

Source: https://huggingface.co/datasets/florencejiang/earnings25
Licence: https://arxiv.org/html/2607.23813v1
Pinned upstream "revision": `b4864bf8f0cd1e3b153e502d45bb29cd46993f21`

## edacc

University of Edinburgh CSTR, EdAcc (2023).

Source: https://huggingface.co/datasets/edinburghcstr/edacc
Licence: https://huggingface.co/datasets/edinburghcstr/edacc/blob/d9ae7bd344f0562b766ec93ee5ce8f2f9568ce66/README.md
Pinned upstream "revision": `d9ae7bd344f0562b766ec93ee5ce8f2f9568ce66`

## fleurs

Conneau et al., FLEURS: Few-shot Learning Evaluation of Universal Representations of Speech (2022), Google.

Source: https://huggingface.co/datasets/google/fleurs
Licence: https://huggingface.co/datasets/google/fleurs/blob/70bb2e84b976b7e960aa89f1c648e09c59f894dd/README.md
Pinned upstream "revision": `70bb2e84b976b7e960aa89f1c648e09c59f894dd`

## hike

HiKE, thetaone-ai; bilingual speakers recorded reviewed, scripted Korean–English sentences.

Source: https://huggingface.co/datasets/thetaone-ai/HiKE
Licence: https://huggingface.co/datasets/thetaone-ai/HiKE/blob/255609b24005e1fcce3f8b3a452260aaf2872cc9/README.md
Pinned upstream "revision": `255609b24005e1fcce3f8b3a452260aaf2872cc9`

## klang

Klang AI, Klang Dialects (2026); opt-in Swedish speakers.

Source: https://huggingface.co/datasets/KlangAI/klang-dialects
Licence: https://huggingface.co/datasets/KlangAI/klang-dialects/blob/4117db6f1c53f5c1ca03309ce2a8060b96653708/LICENSE
Pinned upstream "revision": `4117db6f1c53f5c1ca03309ce2a8060b96653708`

## librispeech-pc

Mehri et al., LibriSpeech-PC; LibriSpeech / OpenSLR 12 audio.

Source: https://www.openslr.org/145/
Licence: https://www.openslr.org/resources/145/about.html
Pinned upstream "revision": `OpenSLR145 manifests sha256:96d4eae2222b29b66437a21959252419bcd4762e5042e71e023790171054d1c0; openslr/librispeech_asr parquet@2b9f39377850ffce6bf6358257ae9f84b2349497`

## mediaspeech

Kolobov et al., MediaSpeech (2021); original YouTube video owners. HF mirror ymoslem/MediaSpeech.

Source: https://www.openslr.org/108/
Licence: https://github.com/NTRLab/MediaSpeech
Pinned upstream "revision": `4008a968760f2187b0c5b2b2db965f1283433059`

## mls

Pratap et al., MLS (2020); source LibriVox readers and works.

Source: https://huggingface.co/datasets/facebook/multilingual_librispeech
Licence: https://www.openslr.org/94/
Pinned upstream "revision": `2e83e61823b4c47dcbcb1980bb88601274127609`

## monsoon

VoiceArena, Monsoon en-IN public test (2026).

Source: https://huggingface.co/datasets/VoiceArena/MonsoonASR-Open-ASR-leaderboard-en-IN
Licence: https://huggingface.co/datasets/VoiceArena/MonsoonASR-Open-ASR-leaderboard-en-IN/blob/bc1da7b42ef6e2853123c97bf6d22067e4802d11/README.md
Pinned upstream "revision": `bc1da7b42ef6e2853123c97bf6d22067e4802d11`

## muscat

MUSCAT authors, bilingual scientific conversations, LREC 2026; native speakers.

Source: https://huggingface.co/datasets/goodpiku/muscat-eval
Licence: https://huggingface.co/datasets/goodpiku/muscat-eval/blob/e5e477cc4aeee6b6f5ea65513914b694fb1030f3/README.md
Pinned upstream "revision": `e5e477cc4aeee6b6f5ea65513914b694fb1030f3`

## notsofar

Microsoft, NOTSOFAR-1 dataset; CC BY 4.0.

Source: https://huggingface.co/datasets/microsoft/NOTSOFAR
Licence: https://huggingface.co/datasets/microsoft/NOTSOFAR/blob/ba8fd0f034ce185fe4d24f47e53b4b8194795f07/LICENSE.txt
Pinned upstream "revision": `ba8fd0f034ce185fe4d24f47e53b4b8194795f07`

## polish-tedx

s512757, Polish TEDx ASR Eval (2026); original TEDx Talks speakers/video owners.

Source: https://huggingface.co/datasets/s512757/polish-tedx-asr-eval
Licence: https://huggingface.co/datasets/s512757/polish-tedx-asr-eval/blob/d0826bb93d2e268dce45b078e0bae56e7d43af21/README.md
Pinned upstream "revision": `d0826bb93d2e268dce45b078e0bae56e7d43af21`

## rev-earnings

Rev, Earnings-22 and Earnings-21 human verbatim transcripts.

Source: https://github.com/revdotcom/speech-datasets
Licence: https://github.com/revdotcom/speech-datasets/blob/c05ab6fd8b4b627d123c922a22a39e993dd37635/earnings22/LICENSE.md
Pinned upstream "revision": `c05ab6fd8b4b627d123c922a22a39e993dd37635`

## rev16

Radford et al. (2023), Rev transcriptionists; underlying podcast creators retain media rights.

Source: https://github.com/revdotcom/speech-datasets/tree/c05ab6fd8b4b627d123c922a22a39e993dd37635/rev16
Licence: https://github.com/revdotcom/speech-datasets/blob/c05ab6fd8b4b627d123c922a22a39e993dd37635/rev16/LICENSE.md
Pinned upstream "revision": `Rev text c05ab6fd8b4b627d123c922a22a39e993dd37635; podcast mirror sanchit-gandhi/rev16_csv@acad9372c439d3d538f846e1c4df9bb9a2730ba1`

## zeroth

Zeroth-Korean, OpenSLR SLR40; test-only parquet redistributed by kresnik/zeroth_korean.

Source: https://www.openslr.org/40/
Licence: https://www.openslr.org/40/
Pinned upstream "revision": `1fe937899f828af822293d05e086200946088bdf`
