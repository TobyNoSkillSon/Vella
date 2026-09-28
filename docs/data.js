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
     "speed_x": 308.2,
     "j_per_min": 6.76,
     "memory_mb": 3356,
     "disk_mb": 2509,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": true,
      "reasons": []
     }
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
     "speed_x": 368.1,
     "j_per_min": 4.68,
     "memory_mb": 1785,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": true,
      "reasons": []
     }
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
     "speed_x": 278.6,
     "j_per_min": 9.42,
     "memory_mb": 1804,
     "disk_mb": 909,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": false,
      "reasons": [
       "English WER +0.12 pt vs FP32 (limit 0.10)",
       "1 clip empty or cut short where FP32 had the words (limit 0)"
      ]
     }
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
     "speed_x": 278.3,
     "j_per_min": 9.51,
     "memory_mb": 1537,
     "disk_mb": 637,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": false,
      "reasons": [
       "English WER +1.41 pt vs FP32 (limit 0.10)",
       "multilingual mean +0.21 pt vs FP32 (limit 0.20)",
       "Swedish +2.80 pt vs FP32 (limit 2.0)",
       "format CER +1.27 pt vs FP32 (limit 0.10)",
       "3 clips empty or cut short where FP32 had the words (limit 0)"
      ]
     }
    }
   },
   "recommended": "BF16",
   "noise_pt": 0.04,
   "tolerance_pt": 0.1,
   "noise_ml_pt": 0.15,
   "tolerance_ml_pt": 0.2
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
     "speed_x": 27.6,
     "j_per_min": 75.47,
     "memory_mb": 4492,
     "disk_mb": 4081,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": true,
      "reasons": []
     }
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
     "speed_x": 41.5,
     "j_per_min": 67.78,
     "memory_mb": 3092,
     "disk_mb": 2468,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": false,
      "reasons": [
       "multilingual mean +0.38 pt vs BF16 (limit 0.10)",
       "Turkish +2.55 pt vs BF16 (limit 2.0)",
       "1 clip empty or cut short where BF16 had the words (limit 0)"
      ]
     }
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
     "speed_x": 57.0,
     "j_per_min": 54.51,
     "memory_mb": 2259,
     "disk_mb": 1608,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": false,
      "reasons": [
       "English WER +3.35 pt vs BF16 (limit 0.10)",
       "multilingual mean +2.54 pt vs BF16 (limit 0.10)",
       "Swedish +7.74 pt vs BF16 (limit 2.0)",
       "Korean +3.40 pt vs BF16 (limit 2.0)",
       "Turkish +3.32 pt vs BF16 (limit 2.0)",
       "Chinese +3.27 pt vs BF16 (limit 2.0)",
       "Polish +2.68 pt vs BF16 (limit 2.0)",
       "format CER +0.45 pt vs BF16 (limit 0.10)",
       "1 clip empty or cut short where BF16 had the words (limit 0)"
      ]
     }
    }
   },
   "recommended": "BF16",
   "noise_pt": 0.0,
   "tolerance_pt": 0.1,
   "noise_ml_pt": 0.0,
   "tolerance_ml_pt": 0.1
  },
  "nemotron-3.5-streaming-0.6b": {
   "precisions": {
    "BF16": {
     "wer": 23.42,
     "format": 10.55,
     "multilingual": {
      "mean": 26.86,
      "macro_wer": 28.06,
      "macro_cer": 24.45,
      "coverage": 9,
      "by_language": {
       "pl": 24.67,
       "de": 17.81,
       "fr": 17.66,
       "es": 16.42,
       "sv": 40.43,
       "tr": 51.38,
       "ja": 14.2,
       "zh": 28.6,
       "ko": 30.56
      }
     },
     "speed_x": 19.6,
     "j_per_min": 78.92,
     "memory_mb": 2700,
     "disk_mb": 1277,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "note": "engine: Self-tested on this Mac against stock MLX (same streamed text; the fused layer is within a small numeric tolerance).",
     "gate": {
      "pass": true,
      "reasons": []
     }
    },
    "8b": {
     "wer": 23.47,
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
     "speed_x": 28.8,
     "j_per_min": 47.02,
     "memory_mb": 1160,
     "disk_mb": 756,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "note": "engine: Self-tested on this Mac against stock MLX (same streamed text; the fused layer is within a small numeric tolerance).",
     "gate": {
      "pass": true,
      "reasons": [
       "streaming trade: 1.47x the speed of BF16 (28.8x vs 19.6x real time, needs 1.25x) for multilingual mean +0.60 pt vs BF16 (limit 0.10); Japanese +2.03 pt vs BF16 (limit 2.0)"
      ]
     }
    },
    "4b": {
     "wer": 32.97,
     "format": 16.19,
     "multilingual": {
      "mean": 36.16,
      "macro_wer": 37.67,
      "macro_cer": 33.13,
      "coverage": 9,
      "by_language": {
       "pl": 36.66,
       "de": 28.15,
       "fr": 21.0,
       "es": 18.49,
       "sv": 55.05,
       "tr": 66.67,
       "ja": 23.27,
       "zh": 39.59,
       "ko": 36.53
      }
     },
     "speed_x": 28.3,
     "j_per_min": 40.2,
     "memory_mb": 895,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "note": "engine: Self-tested on this Mac against stock MLX (same streamed text; the fused layer is within a small numeric tolerance).",
     "gate": {
      "pass": false,
      "reasons": [
       "English WER +9.55 pt vs BF16 (limit 0.10)",
       "multilingual mean +9.30 pt vs BF16 (limit 0.10)",
       "Turkish +15.28 pt vs BF16 (limit 2.0)",
       "Swedish +14.62 pt vs BF16 (limit 2.0)",
       "Polish +12.00 pt vs BF16 (limit 2.0)",
       "Chinese +10.99 pt vs BF16 (limit 2.0)",
       "German +10.34 pt vs BF16 (limit 2.0)",
       "Japanese +9.07 pt vs BF16 (limit 2.0)",
       "Korean +5.97 pt vs BF16 (limit 2.0)",
       "French +3.34 pt vs BF16 (limit 2.0)",
       "Spanish +2.06 pt vs BF16 (limit 2.0)",
       "format CER +5.64 pt vs BF16 (limit 0.10)",
       "14 clips empty or cut short where BF16 had the words (limit 0)"
      ]
     }
    }
   },
   "recommended": "8b",
   "tolerance_pt": 0.1,
   "tolerance_ml_pt": 0.1
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
     "speed_x": 364.6,
     "j_per_min": 5.18,
     "memory_mb": 1753,
     "disk_mb": 1255,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": true,
      "reasons": []
     }
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
     "speed_x": 287.0,
     "j_per_min": 9.43,
     "memory_mb": 1903,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": false,
      "reasons": [
       "multilingual mean +0.17 pt vs BF16 (limit 0.10)"
      ]
     }
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
     "speed_x": 284.4,
     "j_per_min": 9.22,
     "memory_mb": 1664,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": false,
      "reasons": [
       "English WER +0.23 pt vs BF16 (limit 0.10)",
       "multilingual mean +0.92 pt vs BF16 (limit 0.10)",
       "format CER +0.14 pt vs BF16 (limit 0.10)"
      ]
     }
    }
   },
   "recommended": "BF16",
   "noise_pt": 0.02,
   "tolerance_pt": 0.1,
   "noise_ml_pt": 0.0,
   "tolerance_ml_pt": 0.1
  },
  "qwen3-asr-0.6b": {
   "precisions": {
    "BF16": {
     "wer": 15.99,
     "format": 7.26,
     "multilingual": {
      "mean": 20.87,
      "macro_wer": 24.58,
      "macro_cer": 13.47,
      "coverage": 9,
      "by_language": {
       "pl": 25.88,
       "de": 15.56,
       "fr": 16.39,
       "es": 13.16,
       "sv": 49.46,
       "tr": 27.02,
       "ja": 9.13,
       "zh": 14.8,
       "ko": 16.47
      }
     },
     "speed_x": 59.4,
     "j_per_min": 36.78,
     "memory_mb": 2030,
     "disk_mb": 1569,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": true,
      "reasons": []
     }
    },
    "8b": {
     "wer": 16.05,
     "format": 7.3,
     "multilingual": {
      "mean": 21.1,
      "macro_wer": 24.71,
      "macro_cer": 13.88,
      "coverage": 9,
      "by_language": {
       "pl": 25.82,
       "de": 15.92,
       "fr": 16.63,
       "es": 13.76,
       "sv": 49.03,
       "tr": 27.13,
       "ja": 9.19,
       "zh": 15.44,
       "ko": 17.0
      }
     },
     "speed_x": 77.1,
     "j_per_min": 31.5,
     "memory_mb": 1547,
     "disk_mb": 1011,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": false,
      "reasons": [
       "English WER +0.17 pt vs BF16 (limit 0.10)",
       "multilingual mean +0.21 pt vs BF16 (limit 0.10)"
      ]
     }
    },
    "4b": {
     "wer": 17.62,
     "format": 8.48,
     "multilingual": {
      "mean": 30.95,
      "macro_wer": 31.78,
      "macro_cer": 29.28,
      "coverage": 9,
      "by_language": {
       "pl": 32.95,
       "de": 17.63,
       "fr": 22.12,
       "es": 24.08,
       "sv": 59.78,
       "tr": 34.11,
       "ja": 18.07,
       "zh": 18.25,
       "ko": 51.53
      }
     },
     "speed_x": 89.6,
     "j_per_min": 26.42,
     "memory_mb": 1273,
     "disk_mb": 713,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": false,
      "reasons": [
       "English WER +1.75 pt vs BF16 (limit 0.10)",
       "multilingual mean +6.22 pt vs BF16 (limit 0.10)",
       "Swedish +9.03 pt vs BF16 (limit 2.0)",
       "Polish +8.59 pt vs BF16 (limit 2.0)",
       "Japanese +8.43 pt vs BF16 (limit 2.0)",
       "Turkish +8.08 pt vs BF16 (limit 2.0)",
       "Spanish +7.91 pt vs BF16 (limit 2.0)",
       "French +5.57 pt vs BF16 (limit 2.0)",
       "Korean +3.70 pt vs BF16 (limit 2.0)",
       "Chinese +2.63 pt vs BF16 (limit 2.0)",
       "German +2.07 pt vs BF16 (limit 2.0)",
       "format CER +1.14 pt vs BF16 (limit 0.10)"
      ]
     }
    }
   },
   "recommended": "BF16",
   "noise_pt": 0.0,
   "tolerance_pt": 0.1,
   "noise_ml_pt": 0.0,
   "tolerance_ml_pt": 0.1
  },
  "whisper-large-v3": {
   "precisions": {
    "FP16": {
     "wer": 17.68,
     "format": 8.63,
     "multilingual": {
      "mean": 19.52,
      "macro_wer": 17.27,
      "macro_cer": 24.04,
      "coverage": 9,
      "by_language": {
       "pl": 8.53,
       "de": 8.45,
       "fr": 22.75,
       "es": 18.92,
       "sv": 29.89,
       "tr": 15.06,
       "ja": 11.29,
       "zh": 29.06,
       "ko": 31.77
      }
     },
     "speed_x": 27.9,
     "j_per_min": 94.14,
     "memory_mb": 3889,
     "disk_mb": 3088,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": true,
      "reasons": []
     }
    },
    "8b": {
     "wer": 17.78,
     "format": 8.6,
     "multilingual": {
      "mean": 19.58,
      "macro_wer": 17.15,
      "macro_cer": 24.44,
      "coverage": 9,
      "by_language": {
       "pl": 8.53,
       "de": 8.45,
       "fr": 22.67,
       "es": 18.83,
       "sv": 29.25,
       "tr": 15.17,
       "ja": 12.62,
       "zh": 29.12,
       "ko": 31.58
      }
     },
     "speed_x": 32.1,
     "j_per_min": 110.8,
     "memory_mb": 2656,
     "disk_mb": 1650,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": true,
      "reasons": []
     }
    },
    "4b": {
     "wer": 17.75,
     "format": 8.82,
     "multilingual": {
      "mean": 19.33,
      "macro_wer": 17.32,
      "macro_cer": 23.35,
      "coverage": 9,
      "by_language": {
       "pl": 8.53,
       "de": 9.08,
       "fr": 22.99,
       "es": 19.09,
       "sv": 28.82,
       "tr": 15.39,
       "ja": 13.38,
       "zh": 29.88,
       "ko": 26.79
      }
     },
     "speed_x": 38.9,
     "j_per_min": 97.52,
     "memory_mb": 2067,
     "disk_mb": 882,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": false,
      "reasons": [
       "Japanese +2.09 pt vs FP16 (limit 2.0)",
       "format CER +0.18 pt vs FP16 (limit 0.10)",
       "1 clip empty or cut short where FP16 had the words (limit 0)"
      ]
     }
    }
   },
   "recommended": "FP16",
   "tolerance_pt": 0.1,
   "tolerance_ml_pt": 0.1
  },
  "whisper-large-v3-turbo": {
   "precisions": {
    "FP16": {
     "wer": 17.31,
     "format": 7.69,
     "multilingual": {
      "mean": 21.91,
      "macro_wer": 20.97,
      "macro_cer": 23.8,
      "coverage": 9,
      "by_language": {
       "pl": 9.74,
       "de": 9.89,
       "fr": 22.99,
       "es": 19.0,
       "sv": 45.81,
       "tr": 18.38,
       "ja": 13.7,
       "zh": 29.36,
       "ko": 28.33
      }
     },
     "speed_x": 75.8,
     "j_per_min": 58.53,
     "memory_mb": 2459,
     "disk_mb": 1619,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": true,
      "reasons": []
     }
    },
    "8b": {
     "wer": 17.21,
     "format": 7.7,
     "multilingual": {
      "mean": 21.84,
      "macro_wer": 20.81,
      "macro_cer": 23.91,
      "coverage": 9,
      "by_language": {
       "pl": 9.81,
       "de": 10.07,
       "fr": 22.28,
       "es": 19.6,
       "sv": 44.73,
       "tr": 18.38,
       "ja": 13.63,
       "zh": 29.77,
       "ko": 28.33
      }
     },
     "speed_x": 76.8,
     "j_per_min": 64.82,
     "memory_mb": 1922,
     "disk_mb": 868,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": true,
      "reasons": []
     }
    },
    "4b": {
     "wer": 17.8,
     "format": 8.43,
     "multilingual": {
      "mean": 22.03,
      "macro_wer": 20.93,
      "macro_cer": 24.22,
      "coverage": 9,
      "by_language": {
       "pl": 10.05,
       "de": 10.79,
       "fr": 21.96,
       "es": 19.6,
       "sv": 42.37,
       "tr": 20.82,
       "ja": 13.57,
       "zh": 30.41,
       "ko": 28.67
      }
     },
     "speed_x": 80.4,
     "j_per_min": 63.52,
     "memory_mb": 1689,
     "disk_mb": 468,
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": false,
      "reasons": [
       "English WER +0.49 pt vs FP16 (limit 0.10)",
       "Turkish +2.44 pt vs FP16 (limit 2.0)",
       "format CER +0.74 pt vs FP16 (limit 0.10)",
       "2 clips empty or cut short where FP16 had the words (limit 0)"
      ]
     }
    }
   },
   "recommended": "FP16",
   "noise_pt": 0.02,
   "tolerance_pt": 0.1,
   "noise_ml_pt": 0.17,
   "tolerance_ml_pt": 0.22
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
     "disk_mb": 936,
     "suite": "v2-quick",
     "audio_min": 22.5,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "mlx",
     "note": "quick set only (benchmark-table model); energy not recorded: the worker crashed twice per run, so its restarts cannot be separated from background load; engine: No optimized path for this model yet."
    }
   },
   "recommended": "FP32",
   "tolerance_pt": 0.1,
   "tolerance_ml_pt": 0.1
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
     "disk_mb": 459,
     "suite": "v2-quick",
     "audio_min": 22.5,
     "date": "2026-09-26",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "mlx",
     "note": "quick set only (benchmark-table model); engine: The optimized path failed its self-test against stock MLX on this Mac."
    }
   },
   "recommended": "FP32",
   "tolerance_pt": 0.1,
   "tolerance_ml_pt": 0.1
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
      "notes": "Moondream's post-trained version of NVIDIA's Parakeet v3, released in September 2026: the same 0.6B architecture and 25 European languages. In Vella: dictation in those languages, and the model offered for your first dictation. MLX conversion by selcukkubur, tensor-identical to moondream/parakeet-ultra @73175eb; 8b and 4b are made on this Mac from BF16."
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
      "offered": true,
      "notes": "NVIDIA's Parakeet TDT 0.6B v3, released in August 2025: a FastConformer-TDT speech recognizer for 25 European languages. In Vella: dictation in those languages with the unmodified original that Parakeet v3 Ultra is post-trained from. MLX conversions by animaslabs."
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
          "downloadBytes": 4080708834,
          "architecture": "qwen3_asr"
        },
        "8b": {
          "id": "Qwen3-ASR-1.7B-8bit",
          "repository": "mlx-community/Qwen3-ASR-1.7B-8bit",
          "revision": "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
          "downloadBytes": 2467857511,
          "architecture": "qwen3_asr"
        },
        "4b": {
          "id": "Qwen3-ASR-1.7B-4bit",
          "repository": "mlx-community/Qwen3-ASR-1.7B-4bit",
          "revision": "78a389c776a5483b2d0d4ea5494e11012e0d6159",
          "downloadBytes": 1607631587,
          "architecture": "qwen3_asr"
        }
      },
      "offered": true,
      "notes": "Qwen3-ASR 1.7B from Alibaba's Qwen team, released in January 2026: speech recognition built on Qwen3-Omni for 30 languages and 22 Chinese dialects. In Vella: dictation in languages Parakeet lacks, such as Chinese, Japanese and Korean. MLX conversions by mlx-community."
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
      "offered": true,
      "notes": "The smaller Qwen3-ASR from Alibaba's Qwen team, released with the 1.7B in January 2026. In Vella: the same 30 languages in less memory, for Macs with less RAM. MLX conversions by mlx-community."
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
          "downloadBytes": 3087748437,
          "architecture": "whisper"
        },
        "8b": {
          "id": "whisper-large-v3-8bit",
          "repository": "mlx-community/whisper-large-v3-8bit",
          "revision": "7fede54fd97b154a4f5e476646484fc023b1bcdf",
          "downloadBytes": 1650091829,
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
      "offered": true,
      "notes": "OpenAI's Whisper large-v3, released in November 2023: an encoder-decoder transformer trained on 5 million hours of weakly and pseudo-labeled audio. In Vella: dictation in about 100 languages, from a model family other than Parakeet and Qwen. MLX conversions by mlx-community."
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
      "offered": true,
      "notes": "OpenAI's Whisper large-v3 turbo, released in 2024: large-v3 pruned from 32 decoder layers to 4, then fine-tuned. In Vella: much faster dictation in the same languages. MLX conversions by mlx-community."
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
          "downloadBytes": 1276706069,
          "architecture": "nemotron_asr"
        },
        "8b": {
          "id": "nemotron-3.5-asr-streaming-0.6b-8bit",
          "repository": "mlx-community/nemotron-3.5-asr-streaming-0.6b-8bit",
          "revision": "7279359e4481b5e9e185a318bd618e429c6d86cd",
          "downloadBytes": 756246469,
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
      "notes": "NVIDIA's Nemotron 3.5 ASR Streaming 0.6B, released in 2026: a cache-aware FastConformer-RNNT model that transcribes audio as it arrives, for 40 language-locales. In Vella: Streaming mode, typing text while you speak. MLX conversions by mlx-community."
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
      "notes": "Not offered: English only, and less accurate than the offered Parakeet models (v2-quick screening, 26 Sep 2026)."
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
          "downloadBytes": 3148831754,
          "architecture": "voxtral_realtime"
        }
      },
      "offered": false,
      "notes": "Benchmark table only: about 1x real time on an M5 Max, 5.5 GB (smoke screening, 26 Sep 2026)."
    }
  ]
};
