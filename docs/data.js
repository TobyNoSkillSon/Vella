// Written by scripts/pages-data.sh from Resources/benchmarks.json and Resources/models.json.
const VELLA_BENCHMARKS = {
 "schema": 1,
 "hardware": "Apple M5 Max, macOS 26.6",
 "suites": {
  "v2": {
   "id": "vella-v2",
   "hash": "361a9b078db7e6813671f719223dfd27c50f54589a1e292239324ac17071e366",
   "audio_min": 239.7
  },
  "v2-quick": {
   "id": "vella-v2-quick",
   "hash": "5cbda7a5f463d4f12bc4e58982ea16e1f23f3f9361aafc42c3344b6d5fd159b8",
   "audio_min": 22.5
  }
 },
 "models": {
  "parakeet-v3": {
   "precisions": {
    "FP32": {
     "wer": 16.43,
     "format": 7.97,
     "multilingual": {
      "mean": 21.99,
      "macro_wer": 21.99,
      "macro_cer": null,
      "coverage": 5,
      "by_language": {
       "pl": 8.4,
       "de": 12.23,
       "fr": 37.55,
       "es": 28.55,
       "sv": 23.23
      }
     },
     "speed_x": 298.0,
     "j_per_min": 7.06,
     "memory_mb": 3225,
     "disk_mb": 2393,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized"
    },
    "BF16": {
     "wer": 16.43,
     "format": 7.98,
     "multilingual": {
      "mean": 21.99,
      "macro_wer": 21.99,
      "macro_cer": null,
      "coverage": 5,
      "by_language": {
       "pl": 8.28,
       "de": 12.14,
       "fr": 38.27,
       "es": 28.46,
       "sv": 22.8
      }
     },
     "speed_x": 332.3,
     "j_per_min": 6.12,
     "memory_mb": 1896,
     "disk_mb": 2393,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized"
    },
    "8b": {
     "wer": 16.55,
     "format": 8.05,
     "multilingual": {
      "mean": 21.97,
      "macro_wer": 21.97,
      "macro_cer": null,
      "coverage": 5,
      "by_language": {
       "pl": 8.71,
       "de": 12.23,
       "fr": 38.27,
       "es": 27.86,
       "sv": 22.8
      }
     },
     "speed_x": 273.9,
     "j_per_min": 9.95,
     "memory_mb": 1785,
     "disk_mb": 867,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized"
    },
    "4b": {
     "wer": 17.84,
     "format": 9.24,
     "multilingual": {
      "mean": 22.2,
      "macro_wer": 22.2,
      "macro_cer": null,
      "coverage": 5,
      "by_language": {
       "pl": 9.38,
       "de": 11.87,
       "fr": 38.19,
       "es": 25.54,
       "sv": 26.02
      }
     },
     "speed_x": 272.7,
     "j_per_min": 9.81,
     "memory_mb": 1520,
     "disk_mb": 608,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized"
    }
   },
   "recommended": "BF16"
  },
  "qwen3-asr-1.7b": {
   "precisions": {
    "BF16": {
     "wer": 15.03,
     "format": 6.88,
     "multilingual": {
      "mean": 14.1,
      "macro_wer": 15.59,
      "macro_cer": 11.12,
      "coverage": 9,
      "by_language": {
       "pl": 15.41,
       "de": 11.42,
       "fr": 14.16,
       "es": 12.64,
       "sv": 23.66,
       "tr": 16.28,
       "ja": 6.21,
       "zh": 13.1,
       "ko": 14.05
      }
     },
     "speed_x": 24.3,
     "j_per_min": 85.59,
     "memory_mb": 4555,
     "disk_mb": 3892,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized"
    },
    "8b": {
     "wer": 15.07,
     "format": 6.75,
     "multilingual": {
      "mean": 14.58,
      "macro_wer": 16.23,
      "macro_cer": 11.28,
      "coverage": 9,
      "by_language": {
       "pl": 15.77,
       "de": 11.78,
       "fr": 14.16,
       "es": 12.55,
       "sv": 24.3,
       "tr": 18.83,
       "ja": 6.28,
       "zh": 13.1,
       "ko": 14.47
      }
     },
     "speed_x": 36.4,
     "j_per_min": 76.74,
     "memory_mb": 3179,
     "disk_mb": 2354,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized"
    },
    "4b": {
     "wer": 15.37,
     "format": 7.1,
     "multilingual": {
      "mean": 16.84,
      "macro_wer": 18.37,
      "macro_cer": 13.79,
      "coverage": 9,
      "by_language": {
       "pl": 17.9,
       "de": 12.5,
       "fr": 14.56,
       "es": 12.38,
       "sv": 32.47,
       "tr": 20.38,
       "ja": 7.23,
       "zh": 15.26,
       "ko": 18.89
      }
     },
     "speed_x": 50.0,
     "j_per_min": 61.79,
     "memory_mb": 2240,
     "disk_mb": 1533,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized"
    }
   },
   "recommended": "4b"
  },
  "nemotron-3.5-streaming-0.6b": {
   "precisions": {
    "BF16": {
     "wer": 23.44,
     "format": 10.56,
     "multilingual": {
      "mean": 26.84,
      "macro_wer": 28.02,
      "macro_cer": 24.47,
      "coverage": 9,
      "by_language": {
       "pl": 24.54,
       "de": 17.81,
       "fr": 17.66,
       "es": 16.42,
       "sv": 40.43,
       "tr": 51.27,
       "ja": 14.2,
       "zh": 28.6,
       "ko": 30.6
      }
     },
     "speed_x": 16.0,
     "j_per_min": 91.15,
     "memory_mb": 2696,
     "disk_mb": 1218,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "note": "output is bit-identical by construction.; engine: Self-tested on this Mac against stock MLX (identical streamed text); output is bit-identical by construction."
    },
    "8b": {
     "wer": 23.45,
     "format": 10.58,
     "multilingual": {
      "mean": 27.46,
      "macro_wer": 28.49,
      "macro_cer": 25.39,
      "coverage": 9,
      "by_language": {
       "pl": 25.4,
       "de": 18.53,
       "fr": 17.9,
       "es": 16.51,
       "sv": 39.78,
       "tr": 52.82,
       "ja": 16.23,
       "zh": 28.65,
       "ko": 31.28
      }
     },
     "speed_x": 23.6,
     "j_per_min": 66.97,
     "memory_mb": 1225,
     "disk_mb": 721,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "note": "output is bit-identical by construction.; engine: Self-tested on this Mac against stock MLX (identical streamed text); output is bit-identical by construction."
    },
    "4b": {
     "wer": 32.97,
     "format": 16.18,
     "multilingual": {
      "mean": 36.12,
      "macro_wer": 37.64,
      "macro_cer": 33.07,
      "coverage": 9,
      "by_language": {
       "pl": 36.78,
       "de": 27.97,
       "fr": 21.0,
       "es": 18.49,
       "sv": 55.05,
       "tr": 66.56,
       "ja": 23.08,
       "zh": 39.59,
       "ko": 36.53
      }
     },
     "speed_x": 21.4,
     "j_per_min": 74.42,
     "memory_mb": 959,
     "disk_mb": 1218,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "note": "engine: Self-tested on this Mac against stock MLX (identical streamed text); output is bit-identical by construction."
    }
   },
   "recommended": "8b"
  },
  "parakeet-v3-ultra": {
   "precisions": {
    "BF16": {
     "wer": 15.52,
     "format": 5.76,
     "multilingual": {
      "mean": 12.91,
      "macro_wer": 12.91,
      "macro_cer": null,
      "coverage": 5,
      "by_language": {
       "pl": 6.94,
       "de": 8.54,
       "fr": 15.99,
       "es": 13.93,
       "sv": 19.14
      }
     },
     "speed_x": 371.9,
     "j_per_min": 5.36,
     "memory_mb": 1747,
     "disk_mb": 1197,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized"
    },
    "8b": {
     "wer": 15.54,
     "format": 5.69,
     "multilingual": {
      "mean": 13.08,
      "macro_wer": 13.08,
      "macro_cer": null,
      "coverage": 5,
      "by_language": {
       "pl": 6.88,
       "de": 8.81,
       "fr": 16.55,
       "es": 14.02,
       "sv": 19.14
      }
     },
     "speed_x": 242.1,
     "j_per_min": 11.13,
     "memory_mb": 1852,
     "disk_mb": 1197,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized"
    },
    "4b": {
     "wer": 15.78,
     "format": 5.94,
     "multilingual": {
      "mean": 13.83,
      "macro_wer": 13.83,
      "macro_cer": null,
      "coverage": 5,
      "by_language": {
       "pl": 7.92,
       "de": 9.17,
       "fr": 17.26,
       "es": 14.36,
       "sv": 20.43
      }
     },
     "speed_x": 242.4,
     "j_per_min": 10.95,
     "memory_mb": 1583,
     "disk_mb": 1197,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized"
    }
   },
   "recommended": "BF16"
  },
  "qwen3-asr-0.6b": {
   "precisions": {
    "BF16": {
     "wer": 7.43,
     "format": 5.27,
     "multilingual": {
      "mean": 16.86,
      "macro_wer": 22.48,
      "macro_cer": 5.61,
      "coverage": 9,
      "by_language": {
       "pl": 25.6,
       "de": 10.49,
       "fr": 19.61,
       "es": 8.61,
       "sv": 42.37,
       "tr": 28.21,
       "ja": 6.33,
       "zh": 2.9,
       "ko": 7.59
      }
     },
     "speed_x": 57.0,
     "j_per_min": 38.37,
     "memory_mb": 2367,
     "disk_mb": 1497,
     "suite": "v2-quick",
     "audio_min": 22.5,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "note": "quick set only (benchmark-table model)"
    },
    "8b": {
     "wer": 7.86,
     "format": 5.34,
     "multilingual": {
      "mean": 16.57,
      "macro_wer": 21.98,
      "macro_cer": 5.75,
      "coverage": 9,
      "by_language": {
       "pl": 27.05,
       "de": 10.49,
       "fr": 19.61,
       "es": 9.27,
       "sv": 40.68,
       "tr": 24.79,
       "ja": 6.75,
       "zh": 2.9,
       "ko": 7.59
      }
     },
     "speed_x": 72.5,
     "j_per_min": 34.3,
     "memory_mb": 1899,
     "disk_mb": 964,
     "suite": "v2-quick",
     "audio_min": 22.5,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "note": "quick set only (benchmark-table model)"
    },
    "4b": {
     "wer": 9.09,
     "format": 5.34,
     "multilingual": {
      "mean": 20.23,
      "macro_wer": 25.57,
      "macro_cer": 9.54,
      "coverage": 9,
      "by_language": {
       "pl": 40.1,
       "de": 12.96,
       "fr": 21.08,
       "es": 11.26,
       "sv": 40.68,
       "tr": 27.35,
       "ja": 14.35,
       "zh": 2.9,
       "ko": 11.38
      }
     },
     "speed_x": 84.5,
     "j_per_min": 29.27,
     "memory_mb": 1627,
     "disk_mb": 680,
     "suite": "v2-quick",
     "audio_min": 22.5,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "note": "quick set only (benchmark-table model)"
    }
   },
   "recommended": "8b"
  },
  "whisper-large-v3-turbo": {
   "precisions": {
    "8b": {
     "wer": 9.19,
     "format": 4.95,
     "multilingual": {
      "mean": 18.91,
      "macro_wer": 17.94,
      "macro_cer": 20.86,
      "coverage": 9,
      "by_language": {
       "pl": 12.56,
       "de": 8.02,
       "fr": 23.04,
       "es": 13.91,
       "sv": 38.98,
       "tr": 11.11,
       "ja": 16.03,
       "zh": 22.71,
       "ko": 23.85
      }
     },
     "speed_x": 39.6,
     "j_per_min": 92.12,
     "memory_mb": 2101,
     "disk_mb": 828,
     "suite": "v2-quick",
     "audio_min": 22.5,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "mlx",
     "note": "quick set only (benchmark-table model); engine: No optimized path for this model yet."
    },
    "4b": {
     "wer": 9.99,
     "format": 5.48,
     "multilingual": {
      "mean": 19.46,
      "macro_wer": 18.16,
      "macro_cer": 22.07,
      "coverage": 9,
      "by_language": {
       "pl": 12.56,
       "de": 6.17,
       "fr": 24.51,
       "es": 13.91,
       "sv": 40.68,
       "tr": 11.11,
       "ja": 20.25,
       "zh": 23.19,
       "ko": 22.76
      }
     },
     "speed_x": 39.6,
     "j_per_min": 87.14,
     "memory_mb": 1724,
     "disk_mb": 446,
     "suite": "v2-quick",
     "audio_min": 22.5,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "mlx",
     "note": "quick set only (benchmark-table model); engine: No optimized path for this model yet."
    }
   },
   "recommended": null
  },
  "sensevoice-small": {
   "precisions": {
    "FP32": {
     "wer": 11.01,
     "format": 7.77,
     "multilingual": {
      "mean": 8.13,
      "macro_wer": null,
      "macro_cer": 8.13,
      "coverage": 3,
      "by_language": {
       "ja": 4.64,
       "zh": 4.83,
       "ko": 14.91
      }
     },
     "speed_x": 420.0,
     "j_per_min": null,
     "memory_mb": 1548,
     "disk_mb": 893,
     "suite": "v2-quick",
     "audio_min": 22.5,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "mlx",
     "note": "quick set only (benchmark-table model); energy not recorded: the worker crashed twice per run, so its restarts cannot be separated from background load; engine: No optimized path for this model yet."
    }
   },
   "recommended": "FP32"
  },
  "parakeet-tdt-ctc-110m": {
   "precisions": {
    "FP32": {
     "wer": 9.25,
     "format": 6.01,
     "multilingual": {
      "mean": null,
      "macro_wer": null,
      "macro_cer": null,
      "coverage": 0,
      "by_language": {}
     },
     "speed_x": 222.2,
     "j_per_min": 5.03,
     "memory_mb": 889,
     "disk_mb": 438,
     "suite": "v2-quick",
     "audio_min": 22.5,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "mlx",
     "note": "quick set only (benchmark-table model); engine: The optimized path failed its self-test against stock MLX on this Mac."
    }
   },
   "recommended": "FP32"
  }
 },
 "references": {
  "elevenlabs-scribe-v2": {
   "reference": true,
   "estimated": true,
   "name": "ElevenLabs Scribe v2",
   "provider": "ElevenLabs",
   "mode": "dictation",
   "wer": 13.4,
   "range": [
    11.8,
    13.9
   ],
   "multilingual": {
    "by_language": {
     "de": 5.8,
     "fr": 8.2,
     "es": 7.8
    },
    "range": {
     "de": [
      4.5,
      6.7
     ],
     "fr": [
      6.2,
      22.9
     ],
     "es": [
      7.0,
      17.8
     ]
    },
    "coverage": 3
   },
   "source": "Hugging Face Open ASR Leaderboard, English short-form average 3.97% for elevenlabs/scribe_v2 (https://huggingface.co/spaces/hf-audio/open_asr_leaderboard; results https://huggingface.co/datasets/hf-audio/open-asr-leaderboard-results @d2c5b38)",
   "method": "3.97% × 3.38, the median ratio of our v2 WER to the leaderboard WER for the models we measured on both: Parakeet v3 3.38, Qwen3 ASR 1.7B 3.49, Nemotron 3.5 Streaming 2.98. The range uses the lowest and highest ratio.",
   "public_wer": 3.969,
   "ratio": 3.382,
   "anchors": {
    "parakeet-v3": {
     "v2": 16.43,
     "public": 4.85875,
     "ratio": 3.382
    },
    "qwen3-asr-1.7b": {
     "v2": 15.06,
     "public": 4.31125,
     "ratio": 3.493
    },
    "nemotron-3.5-streaming-0.6b": {
     "v2": 23.44,
     "public": 7.8775,
     "ratio": 2.976
    }
   },
   "date": "2026-09-26"
  },
  "azure-speech": {
   "reference": true,
   "estimated": true,
   "name": "Microsoft Azure Speech",
   "provider": "Microsoft",
   "mode": "dictation",
   "wer": 12.9,
   "range": [
    11.3,
    13.3
   ],
   "multilingual": {
    "by_language": {
     "de": 5.0,
     "fr": 7.8,
     "es": 7.7
    },
    "range": {
     "de": [
      3.8,
      5.7
     ],
     "fr": [
      5.9,
      21.9
     ],
     "es": [
      7.0,
      17.7
     ]
    },
    "coverage": 3
   },
   "source": "Hugging Face Open ASR Leaderboard, English short-form average 3.81% for microsoft/azure-speech-07-2026 (https://huggingface.co/spaces/hf-audio/open_asr_leaderboard; results https://huggingface.co/datasets/hf-audio/open-asr-leaderboard-results @d2c5b38)",
   "method": "3.81% × 3.38, the median ratio of our v2 WER to the leaderboard WER for the models we measured on both: Parakeet v3 3.38, Qwen3 ASR 1.7B 3.49, Nemotron 3.5 Streaming 2.98. The range uses the lowest and highest ratio.",
   "public_wer": 3.811,
   "ratio": 3.382,
   "anchors": {
    "parakeet-v3": {
     "v2": 16.43,
     "public": 4.85875,
     "ratio": 3.382
    },
    "qwen3-asr-1.7b": {
     "v2": 15.06,
     "public": 4.31125,
     "ratio": 3.493
    },
    "nemotron-3.5-streaming-0.6b": {
     "v2": 23.44,
     "public": 7.8775,
     "ratio": 2.976
    }
   },
   "date": "2026-09-26"
  }
 }
};
const VELLA_MODELS = {
  "schema": 2,
  "families": [
    {
      "id": "parakeet-v3-ultra",
      "name": "Parakeet v3 Ultra",
      "mode": "dictation",
      "languages": [
        "bg",
        "hr",
        "cs",
        "da",
        "nl",
        "en",
        "et",
        "fi",
        "fr",
        "de",
        "el",
        "hu",
        "it",
        "lv",
        "lt",
        "mt",
        "pl",
        "pt",
        "ro",
        "sk",
        "sl",
        "es",
        "sv",
        "ru",
        "uk"
      ],
      "params": "0.6B",
      "license": "cc-by-4.0",
      "native": "BF16",
      "variants": {
        "BF16": {
          "id": "parakeet-ultra-mlx-bf16",
          "repository": "selcukkubur/parakeet-ultra-mlx",
          "revision": "b554592c50b2a48471add2daa3d46fa9f00fef5e",
          "downloadBytes": 1254840214,
          "architecture": "parakeet"
        },
        "8b": {
          "id": "parakeet-ultra-mlx-8bit-local",
          "derivedFrom": "BF16",
          "bits": 8,
          "groupSize": 64,
          "architecture": "parakeet"
        },
        "4b": {
          "id": "parakeet-ultra-mlx-4bit-local",
          "derivedFrom": "BF16",
          "bits": 4,
          "groupSize": 64,
          "architecture": "parakeet"
        }
      },
      "offered": true,
      "notes": "Moondream's post-trained Parakeet v3 (moondream/parakeet-ultra @73175eb), MLX conversion by selcukkubur (tensor-identical to the upstream weights). No public quantized MLX conversion exists: 8b and 4b are derived locally from BF16 at load (group size 64, the layer selection of the published Parakeet v3 quants)."
    },
    {
      "id": "parakeet-v3",
      "name": "Parakeet v3",
      "mode": "dictation",
      "languages": [
        "bg",
        "hr",
        "cs",
        "da",
        "nl",
        "en",
        "et",
        "fi",
        "fr",
        "de",
        "el",
        "hu",
        "it",
        "lv",
        "lt",
        "mt",
        "pl",
        "pt",
        "ro",
        "sk",
        "sl",
        "es",
        "sv",
        "ru",
        "uk"
      ],
      "params": "0.6B",
      "license": "cc-by-4.0",
      "native": "FP32",
      "variants": {
        "FP32": {
          "id": "parakeet-tdt-0.6b-v3-mlx-fp32",
          "repository": "animaslabs/parakeet-tdt-0.6b-v3-mlx",
          "revision": "b3f0e8a62787b5dd33ebf05be8a5db41661c5eb6",
          "downloadBytes": 2509016021,
          "architecture": "parakeet"
        },
        "BF16": {
          "id": "parakeet-tdt-0.6b-v3-mlx-bf16-local",
          "derivedFrom": "FP32",
          "dtype": "bfloat16",
          "architecture": "parakeet"
        },
        "8b": {
          "id": "parakeet-tdt-0.6b-v3-mlx-8bit",
          "repository": "animaslabs/parakeet-tdt-0.6b-v3-mlx-8bit",
          "revision": "18498133db8b4c8753bf98b3c5b6639b2a791be3",
          "downloadBytes": 909120599,
          "architecture": "parakeet"
        },
        "4b": {
          "id": "parakeet-tdt-0.6b-v3-mlx-4bit",
          "repository": "animaslabs/parakeet-tdt-0.6b-v3-mlx-4bit",
          "revision": "65247a0a9e735426eba06056a9535f7e67dcbbb9",
          "downloadBytes": 637004647,
          "architecture": "parakeet"
        }
      },
      "offered": true
    },
    {
      "id": "parakeet-tdt-ctc-110m",
      "name": "Parakeet TDT-CTC 110M",
      "mode": "dictation",
      "languages": [
        "en"
      ],
      "params": "114M",
      "license": "cc-by-4.0",
      "native": "FP32",
      "variants": {
        "FP32": {
          "id": "parakeet-tdt_ctc-110m-mlx-fp32",
          "repository": "mlx-community/parakeet-tdt_ctc-110m",
          "revision": "d62547387c356a1ab6bb3d85d98b2103f655282e",
          "downloadBytes": 458948617,
          "architecture": "parakeet"
        }
      },
      "offered": false,
      "notes": "Candidate, not screened: English-only 114M hybrid TDT-CTC (TDT decoder used). Loads in the dictation worker on stock MLX; the Parakeet fast path refuses it (1-layer prediction LSTM), so it runs as MLX until the TDT kernel supports one layer. Screening on v2-quick decides."
    },
    {
      "id": "qwen3-asr-1.7b",
      "name": "Qwen3 ASR 1.7B",
      "mode": "dictation",
      "languages": [
        "ar",
        "yue",
        "zh",
        "cs",
        "da",
        "nl",
        "en",
        "fil",
        "fi",
        "fr",
        "de",
        "el",
        "hi",
        "hu",
        "id",
        "it",
        "ja",
        "ko",
        "mk",
        "ms",
        "fa",
        "pl",
        "pt",
        "ro",
        "ru",
        "es",
        "sv",
        "th",
        "tr",
        "vi"
      ],
      "params": "1.7B",
      "license": "apache-2.0",
      "native": "BF16",
      "variants": {
        "BF16": {
          "id": "Qwen3-ASR-1.7B-bf16",
          "repository": "mlx-community/Qwen3-ASR-1.7B-bf16",
          "revision": "e1f6c266914abc5a46e8756e02580f834a6cf8a7",
          "downloadBytes": 4080710353,
          "architecture": "qwen3_asr"
        },
        "8b": {
          "id": "Qwen3-ASR-1.7B-8bit",
          "repository": "mlx-community/Qwen3-ASR-1.7B-8bit",
          "revision": "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
          "downloadBytes": 2467859030,
          "architecture": "qwen3_asr"
        },
        "4b": {
          "id": "Qwen3-ASR-1.7B-4bit",
          "repository": "mlx-community/Qwen3-ASR-1.7B-4bit",
          "revision": "78a389c776a5483b2d0d4ea5494e11012e0d6159",
          "downloadBytes": 1607633106,
          "architecture": "qwen3_asr"
        }
      },
      "offered": true
    },
    {
      "id": "nemotron-3.5-streaming-0.6b",
      "name": "Nemotron 3.5 Streaming",
      "mode": "streaming",
      "languages": [
        "en",
        "es",
        "fr",
        "it",
        "pt",
        "nl",
        "de",
        "tr",
        "ru",
        "ar",
        "hi",
        "ja",
        "ko",
        "vi",
        "uk",
        "pl",
        "sv",
        "cs",
        "nb",
        "da",
        "bg",
        "fi",
        "hr",
        "sk",
        "zh",
        "hu",
        "ro",
        "et"
      ],
      "params": "0.6B",
      "license": "OpenMDW-1.1 (upstream); converter card lists NVIDIA Open Model License",
      "native": "BF16",
      "variants": {
        "BF16": {
          "id": "nemotron-3.5-asr-streaming-0.6b-bf16",
          "repository": "mlx-community/nemotron-3.5-asr-streaming-0.6b",
          "revision": "e550040c0478027ed679b2b6b0d055502c103663",
          "downloadBytes": 1276707588,
          "architecture": "nemotron_asr"
        },
        "8b": {
          "id": "nemotron-3.5-asr-streaming-0.6b-8bit",
          "repository": "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit",
          "revision": "7279359e4481b5e9e185a318bd618e429c6d86cd",
          "downloadBytes": 756247988,
          "architecture": "nemotron_asr"
        },
        "4b": {
          "id": "nemotron-3.5-asr-streaming-0.6b-4bit-local",
          "derivedFrom": "BF16",
          "bits": 4,
          "groupSize": 64,
          "architecture": "nemotron_asr"
        }
      },
      "offered": true,
      "notes": "Native cache-aware streaming recognition; 320 ms context."
    },
    {
      "id": "qwen3-asr-0.6b",
      "name": "Qwen3 ASR 0.6B",
      "mode": "dictation",
      "languages": [
        "ar",
        "yue",
        "zh",
        "cs",
        "da",
        "nl",
        "en",
        "fil",
        "fi",
        "fr",
        "de",
        "el",
        "hi",
        "hu",
        "id",
        "it",
        "ja",
        "ko",
        "mk",
        "ms",
        "fa",
        "pl",
        "pt",
        "ro",
        "ru",
        "es",
        "sv",
        "th",
        "tr",
        "vi"
      ],
      "params": "0.6B",
      "license": "apache-2.0",
      "native": "BF16",
      "variants": {
        "BF16": {
          "id": "Qwen3-ASR-0.6B-bf16",
          "repository": "mlx-community/Qwen3-ASR-0.6B-bf16",
          "revision": "eae2b51f96265328f1e7beced788adb0e4536f92",
          "downloadBytes": 1569436915,
          "architecture": "qwen3_asr"
        },
        "8b": {
          "id": "Qwen3-ASR-0.6B-8bit",
          "repository": "mlx-community/Qwen3-ASR-0.6B-8bit",
          "revision": "89e96d92ba34aca20b3e29fb10cc284097d1219f",
          "downloadBytes": 1010772242,
          "architecture": "qwen3_asr"
        },
        "4b": {
          "id": "Qwen3-ASR-0.6B-4bit",
          "repository": "mlx-community/Qwen3-ASR-0.6B-4bit",
          "revision": "313d850181767edf09f00a9c289becca70e58cd0",
          "downloadBytes": 712779760,
          "architecture": "qwen3_asr"
        }
      },
      "offered": false,
      "notes": "Benchmark table only: worse than Qwen3 ASR 1.7B at every precision for little speed gain (v2-quick screening, 26 Sep 2026)."
    },
    {
      "id": "whisper-large-v3",
      "name": "Whisper large-v3",
      "mode": "dictation",
      "languages": [
        "en",
        "zh",
        "de",
        "es",
        "ru",
        "ko",
        "fr",
        "ja",
        "pt",
        "tr",
        "pl",
        "ca",
        "nl",
        "ar",
        "sv",
        "it",
        "id",
        "hi",
        "fi",
        "vi",
        "he",
        "uk",
        "el",
        "ms",
        "cs",
        "ro",
        "da",
        "hu",
        "ta",
        "no",
        "th",
        "ur",
        "hr",
        "bg",
        "lt",
        "la",
        "mi",
        "ml",
        "cy",
        "sk",
        "te",
        "fa",
        "lv",
        "bn",
        "sr",
        "az",
        "sl",
        "kn",
        "et",
        "mk",
        "br",
        "eu",
        "is",
        "hy",
        "ne",
        "mn",
        "bs",
        "kk",
        "sq",
        "sw",
        "gl",
        "mr",
        "pa",
        "si",
        "km",
        "sn",
        "yo",
        "so",
        "af",
        "oc",
        "ka",
        "be",
        "tg",
        "sd",
        "gu",
        "am",
        "yi",
        "lo",
        "uz",
        "fo",
        "ht",
        "ps",
        "tk",
        "nn",
        "mt",
        "sa",
        "lb",
        "my",
        "bo",
        "tl",
        "mg",
        "as",
        "tt",
        "haw",
        "ln",
        "ha",
        "ba",
        "jw",
        "su",
        "yue"
      ],
      "params": "1.55B",
      "license": "apache-2.0",
      "native": "FP16",
      "variants": {
        "FP16": {
          "id": "whisper-large-v3-asr-fp16",
          "repository": "mlx-community/whisper-large-v3-asr-fp16",
          "revision": "f4b9d561e7f1a5c0587726ff7ff03da2cc80fcf9",
          "downloadBytes": 3087749956,
          "architecture": "whisper"
        },
        "8b": {
          "id": "whisper-large-v3-8bit",
          "repository": "mlx-community/whisper-large-v3-8bit",
          "revision": "7fede54fd97b154a4f5e476646484fc023b1bcdf",
          "downloadBytes": 1650093348,
          "architecture": "whisper",
          "processorSource": {
            "repository": "mlx-community/whisper-large-v3-asr-fp16",
            "revision": "f4b9d561e7f1a5c0587726ff7ff03da2cc80fcf9",
            "files": [
              "preprocessor_config.json",
              "tokenizer.json",
              "tokenizer_config.json",
              "special_tokens_map.json",
              "added_tokens.json",
              "normalizer.json",
              "vocab.json",
              "merges.txt"
            ]
          }
        },
        "4b": {
          "id": "whisper-large-v3-asr-4bit",
          "repository": "mlx-community/whisper-large-v3-asr-4bit",
          "revision": "762b1efb49eb1d10b244236e896425deec3d6a95",
          "downloadBytes": 882232654,
          "architecture": "whisper"
        }
      },
      "offered": false,
      "notes": "Benchmark table only: below the 20x speed floor at 4b and FP16, and less accurate than Qwen3 ASR 1.7B (v2-quick screening, 26 Sep 2026)."
    },
    {
      "id": "whisper-large-v3-turbo",
      "name": "Whisper large-v3 turbo",
      "mode": "dictation",
      "languages": [
        "en",
        "zh",
        "de",
        "es",
        "ru",
        "ko",
        "fr",
        "ja",
        "pt",
        "tr",
        "pl",
        "ca",
        "nl",
        "ar",
        "sv",
        "it",
        "id",
        "hi",
        "fi",
        "vi",
        "he",
        "uk",
        "el",
        "ms",
        "cs",
        "ro",
        "da",
        "hu",
        "ta",
        "no",
        "th",
        "ur",
        "hr",
        "bg",
        "lt",
        "la",
        "mi",
        "ml",
        "cy",
        "sk",
        "te",
        "fa",
        "lv",
        "bn",
        "sr",
        "az",
        "sl",
        "kn",
        "et",
        "mk",
        "br",
        "eu",
        "is",
        "hy",
        "ne",
        "mn",
        "bs",
        "kk",
        "sq",
        "sw",
        "gl",
        "mr",
        "pa",
        "si",
        "km",
        "sn",
        "yo",
        "so",
        "af",
        "oc",
        "ka",
        "be",
        "tg",
        "sd",
        "gu",
        "am",
        "yi",
        "lo",
        "uz",
        "fo",
        "ht",
        "ps",
        "tk",
        "nn",
        "mt",
        "sa",
        "lb",
        "my",
        "bo",
        "tl",
        "mg",
        "as",
        "tt",
        "haw",
        "ln",
        "ha",
        "ba",
        "jw",
        "su",
        "yue"
      ],
      "params": "0.8B",
      "license": "mit",
      "native": "FP16",
      "variants": {
        "FP16": {
          "id": "whisper-large-v3-turbo-asr-fp16",
          "repository": "mlx-community/whisper-large-v3-turbo-asr-fp16",
          "revision": "624c19c9af5603fa73b83bce14d4aeea96156d18",
          "downloadBytes": 1618634653,
          "architecture": "whisper"
        },
        "8b": {
          "id": "whisper-large-v3-turbo-asr-8bit",
          "repository": "mlx-community/whisper-large-v3-turbo-asr-8bit",
          "revision": "f0fca477e0a885ef4a61088d6cbbc8fc25e53268",
          "downloadBytes": 868346887,
          "architecture": "whisper"
        },
        "4b": {
          "id": "whisper-large-v3-turbo-asr-4bit",
          "repository": "mlx-community/whisper-large-v3-turbo-asr-4bit",
          "revision": "321a6ead9f6e0646bc8188a54d2a470e275c6b76",
          "downloadBytes": 468150715,
          "architecture": "whisper"
        }
      },
      "offered": false,
      "notes": "Benchmark table only: dominated by Qwen3 ASR 1.7B (similar speed, higher error, more energy; v2-quick screening, 26 Sep 2026)."
    },
    {
      "id": "sensevoice-small",
      "name": "SenseVoice Small",
      "mode": "dictation",
      "languages": [
        "zh",
        "en",
        "yue",
        "ja",
        "ko"
      ],
      "params": "234M",
      "license": "SenseVoice upstream custom model license (see repository)",
      "native": "FP32",
      "variants": {
        "FP32": {
          "id": "SenseVoiceSmall",
          "repository": "mlx-community/SenseVoiceSmall",
          "revision": "8ddd966bd96243cff196422f81f0c5d955814792",
          "downloadBytes": 936489716,
          "architecture": "sensevoice"
        },
        "4b": {
          "id": "SenseVoiceSmall-4bit",
          "repository": "vanch007/SenseVoiceSmall-4bit",
          "revision": "b5365bac129cf37740aac0a2cfaf283fca0d2d1c",
          "downloadBytes": 152732818,
          "architecture": "sensevoice"
        }
      },
      "offered": false,
      "notes": "Benchmark table only: English WER 11 %, 3 of the 9 benchmark languages, worker crashes on 2 of 207 segments (v2-quick screening, 26 Sep 2026)."
    },
    {
      "id": "granite-4.0-1b-speech",
      "name": "Granite 4.0 1B Speech",
      "mode": "dictation",
      "languages": [],
      "params": "1B",
      "license": "apache-2.0",
      "native": "BF16",
      "variants": {
        "8b": {
          "id": "granite-4.0-1b-speech-8bit",
          "repository": "mlx-community/granite-4.0-1b-speech-8bit",
          "revision": "5ed3098fb331d0131cb2aeafdbacc19841359736",
          "downloadBytes": 2914135282,
          "architecture": "granite_speech"
        },
        "4b": {
          "id": "granite-4.0-1b-speech-4bit",
          "repository": "mlx-community/granite-4.0-1b-speech-4bit",
          "revision": "7e42cf86c0f595f0c38327eae7a90a8c11a17281",
          "downloadBytes": 1995580064,
          "architecture": "granite_speech"
        }
      },
      "offered": false,
      "notes": "Not offered in the app; published benchmark table only."
    },
    {
      "id": "voxtral-mini-4b-realtime",
      "name": "Voxtral Realtime 4B",
      "mode": "streaming",
      "languages": [
        "en",
        "zh",
        "hi",
        "es",
        "ar",
        "fr",
        "pt",
        "ru",
        "de",
        "ja",
        "ko",
        "it",
        "nl"
      ],
      "params": "4B",
      "license": "apache-2.0",
      "native": "BF16",
      "variants": {
        "4b": {
          "id": "Voxtral-Mini-4B-Realtime-2602-4bit",
          "repository": "mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit",
          "revision": "fdebf7b2af834a1db4b8a3c99ab7480b333adf9e",
          "downloadBytes": 3148833321,
          "architecture": "voxtral_realtime"
        }
      },
      "offered": false,
      "notes": "Benchmark table only: about 1x real time on an M5 Max, 5.5 GB (smoke screening, 26 Sep 2026)."
    }
  ]
};
