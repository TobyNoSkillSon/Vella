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
     "speed_x": 302.4,
     "j_per_min": 7.13,
     "memory_mb": 3231,
     "disk_mb": 2509,
     "latency_ms": {
      "p50": 18.1,
      "p95": 28.9,
      "n": 231,
      "kind": "segment"
     },
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
     "wer": 16.45,
     "format": 7.98,
     "multilingual": {
      "mean": 21.91,
      "macro_wer": 21.91,
      "macro_cer": null,
      "coverage": 5,
      "by_language": {
       "pl": 8.4,
       "de": 12.14,
       "fr": 37.95,
       "es": 28.03,
       "sv": 23.01
      }
     },
     "speed_x": 404.1,
     "j_per_min": 5.22,
     "memory_mb": 1735,
     "latency_ms": {
      "p50": 13.8,
      "p95": 22.0,
      "n": 231,
      "kind": "segment"
     },
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": true,
      "reasons": []
     },
     "stock": {
      "wer": 16.39,
      "format": 7.9,
      "multilingual": {
       "mean": 22.14,
       "macro_wer": 22.14,
       "macro_cer": null,
       "coverage": 5,
       "by_language": {
        "pl": 8.59,
        "de": 12.59,
        "fr": 38.27,
        "es": 28.46,
        "sv": 22.8
       }
      },
      "speed_x": 222.7,
      "j_per_min": 6.87,
      "memory_mb": 1735,
      "latency_ms": {
       "p50": 24.3,
       "p95": 46.6,
       "n": 231,
       "kind": "segment"
      },
      "suite": "v2",
      "date": "2026-09-28",
      "hardware": "Apple M5 Max, macOS 26.6"
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
     "speed_x": 277.9,
     "j_per_min": 9.82,
     "memory_mb": 1758,
     "disk_mb": 909,
     "latency_ms": {
      "p50": 20.6,
      "p95": 30.8,
      "n": 231,
      "kind": "segment"
     },
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
     "speed_x": 277.0,
     "j_per_min": 9.64,
     "memory_mb": 1520,
     "disk_mb": 637,
     "latency_ms": {
      "p50": 20.8,
      "p95": 32.0,
      "n": 231,
      "kind": "segment"
     },
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
     "wer": 15.06,
     "format": 6.74,
     "multilingual": {
      "mean": 14.15,
      "macro_wer": 15.6,
      "macro_cer": 11.25,
      "coverage": 9,
      "by_language": {
       "pl": 15.41,
       "de": 10.34,
       "fr": 14.16,
       "es": 12.81,
       "sv": 24.73,
       "tr": 16.17,
       "ja": 6.4,
       "zh": 13.22,
       "ko": 14.13
      }
     },
     "speed_x": 27.3,
     "j_per_min": 75.59,
     "memory_mb": 5092,
     "disk_mb": 4081,
     "latency_ms": {
      "p50": 185.8,
      "p95": 519.6,
      "n": 231,
      "kind": "segment"
     },
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": true,
      "reasons": []
     },
     "stock": {
      "wer": 15.06,
      "format": 6.74,
      "multilingual": {
       "mean": 14.15,
       "macro_wer": 15.6,
       "macro_cer": 11.25,
       "coverage": 9,
       "by_language": {
        "pl": 15.41,
        "de": 10.34,
        "fr": 14.16,
        "es": 12.81,
        "sv": 24.73,
        "tr": 16.17,
        "ja": 6.4,
        "zh": 13.22,
        "ko": 14.13
       }
      },
      "speed_x": 24.0,
      "j_per_min": 85.57,
      "memory_mb": 4600,
      "latency_ms": {
       "p50": 211.0,
       "p95": 586.7,
       "n": 231,
       "kind": "segment"
      },
      "suite": "v2",
      "date": "2026-09-28",
      "hardware": "Apple M5 Max, macOS 26.6"
     }
    },
    "8b": {
     "wer": 15.16,
     "format": 6.65,
     "multilingual": {
      "mean": 14.53,
      "macro_wer": 16.2,
      "macro_cer": 11.2,
      "coverage": 9,
      "by_language": {
       "pl": 15.77,
       "de": 11.78,
       "fr": 14.16,
       "es": 12.04,
       "sv": 24.73,
       "tr": 18.72,
       "ja": 6.34,
       "zh": 13.1,
       "ko": 14.17
      }
     },
     "speed_x": 40.6,
     "j_per_min": 68.06,
     "energy_note": "median of 3 runs, repeat spread 2.5 %; foreign-load flag fired on every run",
     "memory_mb": 3689,
     "disk_mb": 2468,
     "latency_ms": {
      "p50": 126.4,
      "p95": 333.7,
      "n": 231,
      "kind": "segment"
     },
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
     "wer": 18.41,
     "format": 7.19,
     "multilingual": {
      "mean": 16.69,
      "macro_wer": 18.22,
      "macro_cer": 13.64,
      "coverage": 9,
      "by_language": {
       "pl": 18.09,
       "de": 12.23,
       "fr": 14.64,
       "es": 12.38,
       "sv": 32.47,
       "tr": 19.49,
       "ja": 6.91,
       "zh": 16.49,
       "ko": 17.53
      }
     },
     "speed_x": 56.4,
     "j_per_min": 55.94,
     "memory_mb": 2867,
     "disk_mb": 1608,
     "latency_ms": {
      "p50": 93.2,
      "p95": 224.6,
      "n": 231,
      "kind": "segment"
     },
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
     "wer": 23.39,
     "format": 10.55,
     "multilingual": {
      "mean": 26.9,
      "macro_wer": 28.09,
      "macro_cer": 24.53,
      "coverage": 9,
      "by_language": {
       "pl": 24.6,
       "de": 17.81,
       "fr": 17.66,
       "es": 16.42,
       "sv": 40.65,
       "tr": 51.38,
       "ja": 14.33,
       "zh": 28.6,
       "ko": 30.68
      }
     },
     "speed_x": 27.1,
     "j_per_min": 54.37,
     "memory_mb": 1614,
     "disk_mb": 1277,
     "latency_ms": {
      "p50": 0.7,
      "p95": 10.9,
      "n": 15040,
      "kind": "packet",
      "chunk_p50": 9.3,
      "chunk_p95": 12.0
     },
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "note": "engine: Self-tested on this Mac against stock MLX (same streamed text; the fused layer is within a small numeric tolerance).",
     "gate": {
      "pass": true,
      "reasons": []
     },
     "stock": {
      "wer": 23.15,
      "format": 10.47,
      "multilingual": {
       "mean": 27.68,
       "macro_wer": 28.94,
       "macro_cer": 25.16,
       "coverage": 9,
       "by_language": {
        "pl": 25.52,
        "de": 18.17,
        "fr": 18.3,
        "es": 16.17,
        "sv": 43.01,
        "tr": 52.49,
        "ja": 15.16,
        "zh": 29.12,
        "ko": 31.21
       }
      },
      "speed_x": 7.3,
      "j_per_min": 189.33,
      "memory_mb": 2081,
      "latency_ms": {
       "p50": 1.5,
       "p95": 40.0,
       "n": 15040,
       "kind": "packet",
       "chunk_p50": 37.8,
       "chunk_p95": 41.4
      },
      "suite": "v2",
      "date": "2026-09-28",
      "hardware": "Apple M5 Max, macOS 26.6",
      "note": "Stock measured with different sharding (5-way vs 2-way; in streaming each clip depends on its neighbours); rerun pending."
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
     "speed_x": 27.4,
     "j_per_min": 40.11,
     "memory_mb": 1088,
     "disk_mb": 756,
     "latency_ms": {
      "p50": 0.7,
      "p95": 11.0,
      "n": 15040,
      "kind": "packet",
      "chunk_p50": 9.2,
      "chunk_p95": 12.1
     },
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "note": "engine: Self-tested on this Mac against stock MLX (same streamed text; the fused layer is within a small numeric tolerance).",
     "gate": {
      "pass": false,
      "reasons": [
       "multilingual mean +0.55 pt vs BF16 (limit 0.10)"
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
     "speed_x": 30.1,
     "j_per_min": 39.57,
     "memory_mb": 821,
     "latency_ms": {
      "p50": 0.7,
      "p95": 10.1,
      "n": 15040,
      "kind": "packet",
      "chunk_p50": 8.3,
      "chunk_p95": 11.5
     },
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "note": "engine: Self-tested on this Mac against stock MLX (same streamed text; the fused layer is within a small numeric tolerance).",
     "gate": {
      "pass": false,
      "reasons": [
       "English WER +9.59 pt vs BF16 (limit 0.10)",
       "multilingual mean +9.25 pt vs BF16 (limit 0.10)",
       "Turkish +15.28 pt vs BF16 (limit 2.0)",
       "Swedish +14.41 pt vs BF16 (limit 2.0)",
       "Polish +12.06 pt vs BF16 (limit 2.0)",
       "Chinese +10.99 pt vs BF16 (limit 2.0)",
       "German +10.34 pt vs BF16 (limit 2.0)",
       "Japanese +8.94 pt vs BF16 (limit 2.0)",
       "Korean +5.86 pt vs BF16 (limit 2.0)",
       "French +3.34 pt vs BF16 (limit 2.0)",
       "Spanish +2.06 pt vs BF16 (limit 2.0)",
       "format CER +5.63 pt vs BF16 (limit 0.10)",
       "15 clips empty or cut short where BF16 had the words (limit 0)"
      ]
     }
    }
   },
   "recommended": "BF16",
   "tolerance_pt": 0.1,
   "tolerance_ml_pt": 0.1
  },
  "parakeet-v3-ultra": {
   "precisions": {
    "BF16": {
     "wer": 15.54,
     "format": 5.8,
     "multilingual": {
      "mean": 12.91,
      "macro_wer": 12.91,
      "macro_cer": null,
      "coverage": 5,
      "by_language": {
       "pl": 7.0,
       "de": 8.72,
       "fr": 16.07,
       "es": 13.84,
       "sv": 18.92
      }
     },
     "speed_x": 387.4,
     "j_per_min": 4.65,
     "memory_mb": 1740,
     "disk_mb": 1255,
     "latency_ms": {
      "p50": 13.9,
      "p95": 22.4,
      "n": 231,
      "kind": "segment"
     },
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": true,
      "reasons": []
     },
     "stock": {
      "wer": 15.5,
      "format": 5.82,
      "multilingual": {
       "mean": 12.9,
       "macro_wer": 12.91,
       "macro_cer": null,
       "coverage": 5,
       "by_language": {
        "pl": 7.06,
        "de": 8.54,
        "fr": 16.07,
        "es": 13.93,
        "sv": 18.92
       }
      },
      "speed_x": 228.8,
      "j_per_min": 6.67,
      "memory_mb": 1732,
      "latency_ms": {
       "p50": 23.7,
       "p95": 45.4,
       "n": 231,
       "kind": "segment"
      },
      "suite": "v2",
      "date": "2026-09-28",
      "hardware": "Apple M5 Max, macOS 26.6"
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
     "speed_x": 284.4,
     "j_per_min": 9.63,
     "memory_mb": 1862,
     "latency_ms": {
      "p50": 19.7,
      "p95": 30.6,
      "n": 231,
      "kind": "segment"
     },
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
     "speed_x": 281.5,
     "j_per_min": 9.41,
     "memory_mb": 1610,
     "latency_ms": {
      "p50": 20.2,
      "p95": 30.7,
      "n": 231,
      "kind": "segment"
     },
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
     "wer": 15.97,
     "format": 7.29,
     "multilingual": {
      "mean": 20.82,
      "macro_wer": 24.45,
      "macro_cer": 13.55,
      "coverage": 9,
      "by_language": {
       "pl": 25.7,
       "de": 15.47,
       "fr": 16.23,
       "es": 13.24,
       "sv": 49.46,
       "tr": 26.58,
       "ja": 9.32,
       "zh": 14.8,
       "ko": 16.55
      }
     },
     "speed_x": 59.0,
     "j_per_min": 35.91,
     "memory_mb": 2364,
     "disk_mb": 1569,
     "latency_ms": {
      "p50": 86.3,
      "p95": 232.5,
      "n": 231,
      "kind": "segment"
     },
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": true,
      "reasons": []
     },
     "stock": {
      "wer": 15.97,
      "format": 7.29,
      "multilingual": {
       "mean": 20.82,
       "macro_wer": 24.45,
       "macro_cer": 13.55,
       "coverage": 9,
       "by_language": {
        "pl": 25.7,
        "de": 15.47,
        "fr": 16.23,
        "es": 13.24,
        "sv": 49.46,
        "tr": 26.58,
        "ja": 9.32,
        "zh": 14.8,
        "ko": 16.55
       }
      },
      "speed_x": 46.9,
      "j_per_min": 40.2,
      "memory_mb": 2086,
      "latency_ms": {
       "p50": 108.0,
       "p95": 293.1,
       "n": 231,
       "kind": "segment"
      },
      "suite": "v2",
      "date": "2026-09-28",
      "hardware": "Apple M5 Max, macOS 26.6"
     }
    },
    "8b": {
     "wer": 16.14,
     "format": 7.29,
     "multilingual": {
      "mean": 21.02,
      "macro_wer": 24.63,
      "macro_cer": 13.8,
      "coverage": 9,
      "by_language": {
       "pl": 25.52,
       "de": 15.74,
       "fr": 16.23,
       "es": 13.5,
       "sv": 49.46,
       "tr": 27.35,
       "ja": 9.38,
       "zh": 15.2,
       "ko": 16.81
      }
     },
     "speed_x": 76.3,
     "j_per_min": 33.09,
     "memory_mb": 1887,
     "disk_mb": 1011,
     "latency_ms": {
      "p50": 67.4,
      "p95": 173.3,
      "n": 231,
      "kind": "segment"
     },
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
     "wer": 17.72,
     "format": 8.43,
     "multilingual": {
      "mean": 27.04,
      "macro_wer": 31.32,
      "macro_cer": 18.48,
      "coverage": 9,
      "by_language": {
       "pl": 34.29,
       "de": 17.54,
       "fr": 21.8,
       "es": 21.15,
       "sv": 58.49,
       "tr": 34.66,
       "ja": 17.76,
       "zh": 17.43,
       "ko": 20.25
      }
     },
     "speed_x": 89.0,
     "j_per_min": 28.06,
     "memory_mb": 1619,
     "disk_mb": 713,
     "latency_ms": {
      "p50": 57.2,
      "p95": 144.1,
      "n": 231,
      "kind": "segment"
     },
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
     "speed_x": 28.4,
     "j_per_min": 110.9,
     "energy_note": "median of 2 clean runs (110.4–111.4)",
     "memory_mb": 3838,
     "disk_mb": 3088,
     "latency_ms": {
      "p50": 166.6,
      "p95": 393.6,
      "n": 231,
      "kind": "segment"
     },
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
     "speed_x": 33.3,
     "j_per_min": 109.91,
     "energy_note": "median of 3 clean runs (109.7–110.0)",
     "memory_mb": 2653,
     "disk_mb": 1650,
     "latency_ms": {
      "p50": 145.1,
      "p95": 310.4,
      "n": 231,
      "kind": "segment"
     },
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": true,
      "reasons": []
     },
     "stock": {
      "wer": 17.64,
      "format": 8.59,
      "multilingual": {
       "mean": 19.78,
       "macro_wer": 17.45,
       "macro_cer": 24.43,
       "coverage": 9,
       "by_language": {
        "pl": 8.53,
        "de": 8.36,
        "fr": 22.51,
        "es": 19.17,
        "sv": 30.97,
        "tr": 15.17,
        "ja": 12.56,
        "zh": 29.18,
        "ko": 31.55
       }
      },
      "speed_x": 17.3,
      "j_per_min": 171.21,
      "memory_mb": 2832,
      "latency_ms": {
       "p50": 279.2,
       "p95": 715.7,
       "n": 231,
       "kind": "segment"
      },
      "suite": "v2",
      "date": "2026-09-28",
      "hardware": "Apple M5 Max, macOS 26.6"
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
     "speed_x": 41.0,
     "j_per_min": 97.9,
     "memory_mb": 2081,
     "disk_mb": 882,
     "latency_ms": {
      "p50": 130.5,
      "p95": 270.5,
      "n": 231,
      "kind": "segment"
     },
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
   "recommended": "8b",
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
     "speed_x": 76.3,
     "j_per_min": 59.17,
     "memory_mb": 2460,
     "disk_mb": 1619,
     "latency_ms": {
      "p50": 72.5,
      "p95": 116.0,
      "n": 231,
      "kind": "segment"
     },
     "suite": "v2",
     "audio_min": 239.7,
     "date": "2026-09-28",
     "hardware": "Apple M5 Max, macOS 26.6",
     "engine": "optimized",
     "gate": {
      "pass": true,
      "reasons": []
     },
     "stock": {
      "wer": 17.2,
      "format": 7.67,
      "multilingual": {
       "mean": 21.77,
       "macro_wer": 20.78,
       "macro_cer": 23.77,
       "coverage": 9,
       "by_language": {
        "pl": 9.68,
        "de": 9.89,
        "fr": 22.99,
        "es": 19.09,
        "sv": 44.52,
        "tr": 18.49,
        "ja": 13.57,
        "zh": 29.71,
        "ko": 28.03
       }
      },
      "speed_x": 14.7,
      "j_per_min": 140.04,
      "memory_mb": 3346,
      "latency_ms": {
       "p50": 335.4,
       "p95": 950.8,
       "n": 231,
       "kind": "segment"
      },
      "suite": "v2",
      "date": "2026-09-28",
      "hardware": "Apple M5 Max, macOS 26.6"
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
     "speed_x": 77.8,
     "j_per_min": 64.45,
     "memory_mb": 1925,
     "disk_mb": 868,
     "latency_ms": {
      "p50": 71.7,
      "p95": 102.3,
      "n": 231,
      "kind": "segment"
     },
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
     "speed_x": 82.2,
     "j_per_min": 63.11,
     "memory_mb": 1688,
     "disk_mb": 468,
     "latency_ms": {
      "p50": 66.7,
      "p95": 91.6,
      "n": 231,
      "kind": "segment"
     },
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
      "publisher": "Moondream",
      "released": 2026,
      "licence": "CC BY 4.0",
      "summary": "NVIDIA's Parakeet v3, post-trained for dictation in 25 European languages; none from outside Europe",
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
      "publisher": "NVIDIA",
      "released": 2025,
      "licence": "CC BY 4.0",
      "summary": "The unmodified Parakeet v3 that Ultra is post-trained from: the same 25 European languages, no others",
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
      "publisher": "Qwen (Alibaba)",
      "released": 2026,
      "licence": "Apache-2.0",
      "summary": "Dictation in 30 languages, including Chinese, Japanese and Korean, which Parakeet lacks; slower than Parakeet",
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
      "publisher": "Qwen (Alibaba)",
      "released": 2026,
      "licence": "Apache-2.0",
      "summary": "The smaller Qwen3 ASR: the same 30 languages in less memory, a little less accurate than the 1.7B",
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
      "publisher": "OpenAI",
      "released": 2023,
      "licence": "Apache-2.0",
      "summary": "Dictation in about 100 languages, the most of any model here, from a family other than Parakeet and Qwen",
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
      "publisher": "OpenAI",
      "released": 2024,
      "licence": "MIT",
      "summary": "Whisper large-v3 with 4 decoder layers instead of 32: the same languages, much faster, a little less accurate outside English",
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
      "publisher": "NVIDIA",
      "released": 2026,
      "licence": "OpenMDW-1.1 (MLX conversion: NVIDIA Open Model License)",
      "summary": "Transcribes audio as it arrives, so Streaming mode types while you speak; not used for Dictation",
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
