// Written by scripts/pages-data.sh from Resources/benchmarks.json and Resources/models.json.
const VELLA_BENCHMARKS = {
  "schema": 2,
  "figures_pending": false,
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
      "noise_pt": 0.04,
      "tolerance_pt": 0.1,
      "noise_ml_pt": 0.15,
      "tolerance_ml_pt": 0.2,
      "tiers": {
        "16": {
          "precision": "BF16",
          "presence": {
            "offered": true,
            "reasons": []
          },
          "gate": {
            "status": "pass",
            "reasons": [],
            "loss": []
          },
          "standard": {
            "wer": 16.37,
            "format": 7.84,
            "multilingual": {
              "mean": 21.3,
              "macro_wer": 21.3,
              "macro_cer": null,
              "coverage": 5,
              "by_language": {
                "pl": 8.59,
                "de": 12.59,
                "fr": 34.92,
                "es": 27.6,
                "sv": 22.8
              }
            },
            "speed_x": 257.7,
            "j_per_min": 6.346,
            "energy_note": "median of 3 clean brackets (6.341–6.407 J/min)",
            "memory_mb": 1794,
            "latency_ms": {
              "p50": 24.6,
              "p95": 46.8,
              "n": 188,
              "kind": "segment"
            },
            "disk_mb": 1255,
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": null,
              "performance_suite": "v2-quick"
            },
            "engine": "mlx",
            "recipe": {
              "layers": {
                "all": "bf16"
              },
              "converted_from": "fp32",
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "pass",
              "reasons": [],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_exact": {
            "wer": 16.42,
            "format": 7.92,
            "multilingual": {
              "mean": 20.89,
              "macro_wer": 20.9,
              "macro_cer": null,
              "coverage": 5,
              "by_language": {
                "pl": 8.34,
                "de": 12.14,
                "fr": 33.81,
                "es": 27.6,
                "sv": 22.58
              }
            },
            "speed_x": 463.9,
            "j_per_min": 4.812,
            "energy_note": "median of 3 clean brackets (4.774–4.858 J/min)",
            "memory_mb": 1777,
            "latency_ms": {
              "p50": 14.8,
              "p95": 21.6,
              "n": 188,
              "kind": "segment"
            },
            "disk_mb": 1255,
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "bf16"
              },
              "converted_from": "fp32",
              "kernels": [
                "decoder",
                "encoder"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {}
            },
            "gate": {
              "status": "pass",
              "reasons": [],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_fast": {
            "wer": 16.42,
            "format": 7.92,
            "multilingual": {
              "mean": 20.79,
              "macro_wer": 20.79,
              "macro_cer": null,
              "coverage": 5,
              "by_language": {
                "pl": 8.4,
                "de": 12.14,
                "fr": 33.81,
                "es": 27.0,
                "sv": 22.58
              }
            },
            "speed_x": 494.3,
            "j_per_min": 4.703,
            "energy_note": "median of 3 clean brackets (4.456–4.726 J/min)",
            "memory_mb": 1765,
            "latency_ms": {
              "p50": 13.6,
              "p95": 21.7,
              "n": 188,
              "kind": "segment"
            },
            "disk_mb": 1255,
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "bf16"
              },
              "converted_from": "fp32",
              "kernels": [
                "decoder",
                "encoder",
                "nax_gemm"
              ],
              "inexact": [
                "nax_gemm"
              ],
              "gate_revision": "native-kernels-10",
              "env": {}
            },
            "gate": {
              "status": "pass",
              "reasons": [],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_fast"
          }
        },
        "8": {
          "precision": "8b",
          "presence": {
            "offered": true,
            "reasons": []
          },
          "gate": {
            "status": "pass",
            "reasons": [],
            "loss": []
          },
          "standard": {
            "wer": 16.4,
            "format": 7.92,
            "multilingual": {
              "mean": 20.96,
              "macro_wer": 20.96,
              "macro_cer": null,
              "coverage": 5,
              "by_language": {
                "pl": 8.59,
                "de": 11.87,
                "fr": 33.97,
                "es": 27.77,
                "sv": 22.58
              }
            },
            "speed_x": 241.2,
            "j_per_min": 9.047,
            "energy_note": "median of 3 clean brackets (9.034–9.092 J/min)",
            "memory_mb": 1279,
            "latency_ms": {
              "p50": 26.1,
              "p95": 52.2,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": null,
              "performance_suite": "v2-quick"
            },
            "engine": "mlx",
            "recipe": {
              "layers": {
                "all": "affine-8 g64",
                "decoder": "bf16",
                "joint": "bf16"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "pass",
              "reasons": [],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_exact": {
            "wer": 16.35,
            "format": 7.81,
            "multilingual": {
              "mean": 21.05,
              "macro_wer": 21.05,
              "macro_cer": null,
              "coverage": 5,
              "by_language": {
                "pl": 8.47,
                "de": 12.32,
                "fr": 33.81,
                "es": 27.86,
                "sv": 22.8
              }
            },
            "speed_x": 363.3,
            "j_per_min": 8.677,
            "energy_note": "median of 3 clean brackets (8.675–8.753 J/min)",
            "memory_mb": 1883,
            "latency_ms": {
              "p50": 18.6,
              "p95": 28.7,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-8 g64",
                "decoder": "bf16",
                "joint": "bf16"
              },
              "kernels": [
                "decoder",
                "encoder"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {}
            },
            "gate": {
              "status": "pass",
              "reasons": [],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_fast": {
            "wer": 16.3,
            "format": 7.85,
            "multilingual": {
              "mean": 20.94,
              "macro_wer": 20.93,
              "macro_cer": null,
              "coverage": 5,
              "by_language": {
                "pl": 8.59,
                "de": 12.14,
                "fr": 33.89,
                "es": 27.69,
                "sv": 22.37
              }
            },
            "speed_x": 504.4,
            "j_per_min": 5.405,
            "energy_note": "median of 3 clean brackets (5.391–5.422 J/min)",
            "memory_mb": 1342,
            "latency_ms": {
              "p50": 13.5,
              "p95": 21.5,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-8 g64",
                "decoder": "bf16",
                "joint": "bf16"
              },
              "kernels": [
                "decoder",
                "encoder",
                "int8_gemm"
              ],
              "inexact": [
                "int8_gemm"
              ],
              "gate_revision": "native-kernels-10",
              "env": {
                "VELLA_PARAKEET_INT8": "1"
              }
            },
            "gate": {
              "status": "pass",
              "reasons": [],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_fast"
          }
        },
        "4": {
          "precision": "4b",
          "presence": {
            "offered": false,
            "reasons": [
              "3 clips empty or cut short where 16 had the words"
            ]
          },
          "gate": {
            "status": "fail",
            "reasons": [
              "English WER +0.53 pt vs 16 (limit 0.10)",
              "Swedish +3.01 pt vs 16 (limit 2.0)",
              "3 clips empty or cut short where 16 had the words (limit 0)"
            ],
            "loss": [
              "English WER +0.53 pt",
              "Swedish +3.01 pt"
            ]
          },
          "standard": {
            "wer": 17.02,
            "format": 7.68,
            "multilingual": {
              "mean": 20.48,
              "macro_wer": 20.48,
              "macro_cer": null,
              "coverage": 5,
              "by_language": {
                "pl": 8.83,
                "de": 12.05,
                "fr": 30.47,
                "es": 25.45,
                "sv": 25.59
              }
            },
            "speed_x": 242.3,
            "j_per_min": 8.839,
            "energy_note": "median of 3 clean brackets (8.774–8.839 J/min)",
            "memory_mb": 1024,
            "latency_ms": {
              "p50": 26.2,
              "p95": 51.8,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": null,
              "performance_suite": "v2-quick"
            },
            "engine": "mlx",
            "recipe": {
              "layers": {
                "all": "affine-4 g64",
                "decoder": "bf16",
                "joint": "bf16"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +0.65 pt vs 16 (limit 0.10)",
                "Swedish +2.80 pt vs 16 (limit 2.0)",
                "2 clips empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "2 clips empty or cut short where 16 had the words"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_exact": {
            "wer": 16.9,
            "format": 7.69,
            "multilingual": {
              "mean": 20.68,
              "macro_wer": 20.68,
              "macro_cer": null,
              "coverage": 5,
              "by_language": {
                "pl": 8.77,
                "de": 11.96,
                "fr": 30.23,
                "es": 26.83,
                "sv": 25.59
              }
            },
            "speed_x": 365.0,
            "j_per_min": 8.493,
            "energy_note": "median of 3 clean brackets (8.464–8.496 J/min)",
            "memory_mb": 1628,
            "latency_ms": {
              "p50": 18.4,
              "p95": 28.3,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-4 g64",
                "decoder": "bf16",
                "joint": "bf16"
              },
              "kernels": [
                "decoder",
                "encoder"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +0.53 pt vs 16 (limit 0.10)",
                "Swedish +2.80 pt vs 16 (limit 2.0)",
                "3 clips empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "3 clips empty or cut short where 16 had the words"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_fast": {
            "wer": 16.95,
            "format": 7.69,
            "multilingual": {
              "mean": 20.77,
              "macro_wer": 20.77,
              "macro_cer": null,
              "coverage": 5,
              "by_language": {
                "pl": 8.71,
                "de": 12.05,
                "fr": 30.39,
                "es": 27.09,
                "sv": 25.59
              }
            },
            "speed_x": 512.3,
            "j_per_min": 5.202,
            "energy_note": "median of 3 clean brackets (5.193–5.227 J/min)",
            "memory_mb": 1088,
            "latency_ms": {
              "p50": 13.5,
              "p95": 21.2,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-4 g64",
                "decoder": "bf16",
                "joint": "bf16"
              },
              "kernels": [
                "decoder",
                "encoder",
                "int4_gemm"
              ],
              "inexact": [
                "int4_gemm"
              ],
              "gate_revision": "native-kernels-10",
              "env": {
                "VELLA_PARAKEET_INT4": "1"
              }
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +0.57 pt vs 16 (limit 0.10)",
                "Swedish +2.80 pt vs 16 (limit 2.0)",
                "3 clips empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "3 clips empty or cut short where 16 had the words"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_fast"
          }
        }
      }
    },
    "qwen3-asr-1.7b": {
      "noise_pt": 0.0,
      "tolerance_pt": 0.1,
      "noise_ml_pt": 0.0,
      "tolerance_ml_pt": 0.1,
      "tiers": {
        "16": {
          "precision": "BF16",
          "presence": {
            "offered": true,
            "reasons": []
          },
          "gate": {
            "status": "pass",
            "reasons": [],
            "loss": []
          },
          "standard": {
            "wer": 15.0,
            "format": 6.67,
            "multilingual": {
              "mean": 14.04,
              "macro_wer": 15.54,
              "macro_cer": 11.02,
              "coverage": 9,
              "by_language": {
                "pl": 15.53,
                "de": 10.34,
                "fr": 14.48,
                "es": 12.73,
                "sv": 23.23,
                "tr": 16.94,
                "ja": 4.06,
                "zh": 13.22,
                "ko": 15.79
              }
            },
            "speed_x": 26.6,
            "j_per_min": 81.025,
            "energy_note": "median of 3 clean brackets (80.951–81.043 J/min)",
            "memory_mb": 4624,
            "latency_ms": {
              "p50": 226.1,
              "p95": 596.2,
              "n": 188,
              "kind": "segment"
            },
            "disk_mb": 4081,
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": null,
              "performance_suite": "v2-quick"
            },
            "engine": "mlx",
            "recipe": {
              "layers": {
                "all": "bf16"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "pass",
              "reasons": [],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_exact": {
            "wer": 15.0,
            "format": 6.67,
            "multilingual": {
              "mean": 14.04,
              "macro_wer": 15.54,
              "macro_cer": 11.02,
              "coverage": 9,
              "by_language": {
                "pl": 15.53,
                "de": 10.34,
                "fr": 14.48,
                "es": 12.73,
                "sv": 23.23,
                "tr": 16.94,
                "ja": 4.06,
                "zh": 13.22,
                "ko": 15.79
              }
            },
            "speed_x": 29.6,
            "j_per_min": 72.731,
            "energy_note": "median of 3 clean brackets (72.338–73.029 J/min)",
            "memory_mb": 5118,
            "latency_ms": {
              "p50": 205.0,
              "p95": 537.9,
              "n": 188,
              "kind": "segment"
            },
            "disk_mb": 4081,
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "bf16"
              },
              "kernels": [
                "decoder",
                "encoder"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {}
            },
            "gate": {
              "status": "pass",
              "reasons": [],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_fast": {
            "wer": 15.0,
            "format": 6.67,
            "multilingual": {
              "mean": 14.04,
              "macro_wer": 15.54,
              "macro_cer": 11.02,
              "coverage": 9,
              "by_language": {
                "pl": 15.53,
                "de": 10.34,
                "fr": 14.48,
                "es": 12.73,
                "sv": 23.23,
                "tr": 16.94,
                "ja": 4.06,
                "zh": 13.22,
                "ko": 15.79
              }
            },
            "speed_x": 28.3,
            "j_per_min": 72.32,
            "energy_note": "median of 3 clean brackets (72.083–73.302 J/min)",
            "memory_mb": 5101,
            "latency_ms": {
              "p50": 216.2,
              "p95": 558.7,
              "n": 188,
              "kind": "segment"
            },
            "disk_mb": 4081,
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "bf16"
              },
              "kernels": [
                "decoder",
                "encoder"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {}
            },
            "gate": {
              "status": "pass",
              "reasons": [],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_exact"
          }
        },
        "8": {
          "precision": "8b",
          "presence": {
            "offered": false,
            "reasons": [
              "1 clip empty or cut short where 16 had the words",
              "Turkish +42.64 pt vs 16 (presence limit +10.0)"
            ]
          },
          "gate": {
            "status": "fail",
            "reasons": [
              "English WER +0.11 pt vs 16 (limit 0.10)",
              "multilingual mean +4.98 pt vs 16 (limit 0.10)",
              "Turkish +42.64 pt vs 16 (limit 2.0)",
              "1 clip empty or cut short where 16 had the words (limit 0)"
            ],
            "loss": [
              "English WER +0.11 pt",
              "multilingual mean +4.98 pt",
              "Turkish +42.64 pt"
            ]
          },
          "standard": {
            "wer": 15.11,
            "format": 6.59,
            "multilingual": {
              "mean": 19.01,
              "macro_wer": 22.89,
              "macro_cer": 11.26,
              "coverage": 9,
              "by_language": {
                "pl": 15.96,
                "de": 11.78,
                "fr": 14.64,
                "es": 11.95,
                "sv": 23.44,
                "tr": 59.58,
                "ja": 4.06,
                "zh": 13.1,
                "ko": 16.62
              }
            },
            "speed_x": 36.7,
            "j_per_min": 71.349,
            "energy_note": "median of 3 clean brackets (71.161–71.360 J/min)",
            "memory_mb": 3197,
            "latency_ms": {
              "p50": 166.7,
              "p95": 418.0,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": null,
              "performance_suite": "v2-quick"
            },
            "engine": "mlx",
            "recipe": {
              "layers": {
                "all": "affine-8 g64"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +0.11 pt vs 16 (limit 0.10)",
                "multilingual mean +4.98 pt vs 16 (limit 0.10)",
                "Turkish +42.64 pt vs 16 (limit 2.0)",
                "1 clip empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "1 clip empty or cut short where 16 had the words",
                  "Turkish +42.64 pt vs 16 (presence limit +10.0)"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_exact": {
            "wer": 15.11,
            "format": 6.59,
            "multilingual": {
              "mean": 19.01,
              "macro_wer": 22.89,
              "macro_cer": 11.26,
              "coverage": 9,
              "by_language": {
                "pl": 15.96,
                "de": 11.78,
                "fr": 14.64,
                "es": 11.95,
                "sv": 23.44,
                "tr": 59.58,
                "ja": 4.06,
                "zh": 13.1,
                "ko": 16.62
              }
            },
            "speed_x": 44.3,
            "j_per_min": 64.81,
            "energy_note": "median of 3 clean brackets (63.995–64.900 J/min)",
            "memory_mb": 3721,
            "latency_ms": {
              "p50": 139.6,
              "p95": 347.3,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-8 g64"
              },
              "kernels": [
                "decoder",
                "encoder"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +0.11 pt vs 16 (limit 0.10)",
                "multilingual mean +4.98 pt vs 16 (limit 0.10)",
                "Turkish +42.64 pt vs 16 (limit 2.0)",
                "1 clip empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "1 clip empty or cut short where 16 had the words",
                  "Turkish +42.64 pt vs 16 (presence limit +10.0)"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_fast": {
            "wer": 15.11,
            "format": 6.59,
            "multilingual": {
              "mean": 19.01,
              "macro_wer": 22.89,
              "macro_cer": 11.26,
              "coverage": 9,
              "by_language": {
                "pl": 15.96,
                "de": 11.78,
                "fr": 14.64,
                "es": 11.95,
                "sv": 23.44,
                "tr": 59.58,
                "ja": 4.06,
                "zh": 13.1,
                "ko": 16.62
              }
            },
            "speed_x": 44.3,
            "j_per_min": 64.498,
            "energy_note": "median of 3 clean brackets (64.429–64.695 J/min)",
            "memory_mb": 3721,
            "latency_ms": {
              "p50": 139.4,
              "p95": 347.2,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-8 g64"
              },
              "kernels": [
                "decoder",
                "encoder"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +0.11 pt vs 16 (limit 0.10)",
                "multilingual mean +4.98 pt vs 16 (limit 0.10)",
                "Turkish +42.64 pt vs 16 (limit 2.0)",
                "1 clip empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "1 clip empty or cut short where 16 had the words",
                  "Turkish +42.64 pt vs 16 (presence limit +10.0)"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_exact"
          }
        },
        "4": {
          "precision": "4b",
          "presence": {
            "offered": false,
            "reasons": [
              "1 clip empty or cut short where 16 had the words"
            ]
          },
          "gate": {
            "status": "fail",
            "reasons": [
              "English WER +3.32 pt vs 16 (limit 0.10)",
              "multilingual mean +1.93 pt vs 16 (limit 0.10)",
              "Swedish +7.10 pt vs 16 (limit 2.0)",
              "Turkish +3.32 pt vs 16 (limit 2.0)",
              "Polish +2.44 pt vs 16 (limit 2.0)",
              "format CER +0.35 pt vs 16 (limit 0.10)",
              "1 clip empty or cut short where 16 had the words (limit 0)"
            ],
            "loss": [
              "English WER +3.32 pt",
              "multilingual mean +1.93 pt",
              "Swedish +7.10 pt",
              "Turkish +3.32 pt",
              "Polish +2.44 pt",
              "format CER +0.35 pt"
            ]
          },
          "standard": {
            "wer": 18.32,
            "format": 7.03,
            "multilingual": {
              "mean": 15.96,
              "macro_wer": 17.98,
              "macro_cer": 11.92,
              "coverage": 9,
              "by_language": {
                "pl": 17.97,
                "de": 12.23,
                "fr": 14.8,
                "es": 12.3,
                "sv": 30.32,
                "tr": 20.27,
                "ja": 4.63,
                "zh": 13.92,
                "ko": 17.23
              }
            },
            "speed_x": 47.3,
            "j_per_min": 56.234,
            "energy_note": "median of 3 clean brackets (56.048–56.242 J/min)",
            "memory_mb": 2367,
            "latency_ms": {
              "p50": 131.8,
              "p95": 302.8,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": null,
              "performance_suite": "v2-quick"
            },
            "engine": "mlx",
            "recipe": {
              "layers": {
                "all": "affine-4 g64"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +3.32 pt vs 16 (limit 0.10)",
                "multilingual mean +1.93 pt vs 16 (limit 0.10)",
                "Swedish +7.10 pt vs 16 (limit 2.0)",
                "Turkish +3.32 pt vs 16 (limit 2.0)",
                "Polish +2.44 pt vs 16 (limit 2.0)",
                "format CER +0.35 pt vs 16 (limit 0.10)",
                "1 clip empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "1 clip empty or cut short where 16 had the words"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_exact": {
            "wer": 18.32,
            "format": 7.03,
            "multilingual": {
              "mean": 15.96,
              "macro_wer": 17.98,
              "macro_cer": 11.92,
              "coverage": 9,
              "by_language": {
                "pl": 17.97,
                "de": 12.23,
                "fr": 14.8,
                "es": 12.3,
                "sv": 30.32,
                "tr": 20.27,
                "ja": 4.63,
                "zh": 13.92,
                "ko": 17.23
              }
            },
            "speed_x": 61.5,
            "j_per_min": 51.432,
            "energy_note": "median of 3 clean brackets (51.266–51.476 J/min)",
            "memory_mb": 2890,
            "latency_ms": {
              "p50": 103.3,
              "p95": 234.0,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-4 g64"
              },
              "kernels": [
                "decoder",
                "encoder"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +3.32 pt vs 16 (limit 0.10)",
                "multilingual mean +1.93 pt vs 16 (limit 0.10)",
                "Swedish +7.10 pt vs 16 (limit 2.0)",
                "Turkish +3.32 pt vs 16 (limit 2.0)",
                "Polish +2.44 pt vs 16 (limit 2.0)",
                "format CER +0.35 pt vs 16 (limit 0.10)",
                "1 clip empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "1 clip empty or cut short where 16 had the words"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_fast": {
            "wer": 18.32,
            "format": 7.03,
            "multilingual": {
              "mean": 15.96,
              "macro_wer": 17.98,
              "macro_cer": 11.92,
              "coverage": 9,
              "by_language": {
                "pl": 17.97,
                "de": 12.23,
                "fr": 14.8,
                "es": 12.3,
                "sv": 30.32,
                "tr": 20.27,
                "ja": 4.63,
                "zh": 13.92,
                "ko": 17.23
              }
            },
            "speed_x": 61.5,
            "j_per_min": 51.456,
            "energy_note": "median of 3 clean brackets (51.451–51.521 J/min)",
            "memory_mb": 2891,
            "latency_ms": {
              "p50": 103.3,
              "p95": 233.8,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-4 g64"
              },
              "kernels": [
                "decoder",
                "encoder"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +3.32 pt vs 16 (limit 0.10)",
                "multilingual mean +1.93 pt vs 16 (limit 0.10)",
                "Swedish +7.10 pt vs 16 (limit 2.0)",
                "Turkish +3.32 pt vs 16 (limit 2.0)",
                "Polish +2.44 pt vs 16 (limit 2.0)",
                "format CER +0.35 pt vs 16 (limit 0.10)",
                "1 clip empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "1 clip empty or cut short where 16 had the words"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_exact"
          }
        }
      }
    },
    "nemotron-3.5-streaming-0.6b": {
      "tolerance_pt": 0.1,
      "tolerance_ml_pt": 0.1,
      "tiers": {
        "16": {
          "precision": "BF16",
          "presence": {
            "offered": true,
            "reasons": []
          },
          "gate": {
            "status": "pass",
            "reasons": [],
            "loss": []
          },
          "standard": {
            "wer": 23.5,
            "format": 10.89,
            "multilingual": {
              "mean": 27.05,
              "macro_wer": 28.09,
              "macro_cer": 24.99,
              "coverage": 9,
              "by_language": {
                "pl": 25.33,
                "de": 17.99,
                "fr": 17.82,
                "es": 15.99,
                "sv": 40.22,
                "tr": 51.16,
                "ja": 15.47,
                "zh": 29.01,
                "ko": 30.49
              }
            },
            "speed_x": 7.3,
            "j_per_min": 188.248,
            "energy_note": "median of 3 clean brackets (185.768–193.595 J/min)",
            "memory_mb": 2253,
            "latency_ms": {
              "p50": 1.4,
              "p95": 39.8,
              "n": 15040,
              "kind": "packet",
              "chunk_p50": 37.8,
              "chunk_p95": 40.9
            },
            "disk_mb": 1277,
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": null,
              "performance_suite": "v2-quick"
            },
            "engine": "mlx",
            "recipe": {
              "layers": {
                "all": "bf16"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "pass",
              "reasons": [],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_exact": {
            "wer": 23.39,
            "format": 10.57,
            "multilingual": {
              "mean": 27.18,
              "macro_wer": 28.56,
              "macro_cer": 24.43,
              "coverage": 9,
              "by_language": {
                "pl": 23.69,
                "de": 19.51,
                "fr": 17.82,
                "es": 16.25,
                "sv": 41.94,
                "tr": 52.16,
                "ja": 14.27,
                "zh": 28.95,
                "ko": 30.07
              }
            },
            "speed_x": 19.3,
            "j_per_min": 80.334,
            "energy_note": "median of 3 clean brackets (78.560–80.503 J/min)",
            "memory_mb": 2725,
            "latency_ms": {
              "p50": 0.5,
              "p95": 15.2,
              "n": 15040,
              "kind": "packet",
              "chunk_p50": 14.1,
              "chunk_p95": 16.1
            },
            "disk_mb": 1277,
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "bf16"
              },
              "kernels": [
                "batched_decode",
                "coalesce",
                "f32_weights",
                "keep_cache",
                "kv_cache",
                "mel_batch",
                "position_cache"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {
                "VELLA_NEMO_KEEPCACHE": "1"
              }
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "multilingual mean +0.13 pt vs 16 (limit 0.10)",
                "5 clips empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "5 clips empty or cut short where 16 had the words"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_fast": {
            "wer": 23.35,
            "format": 10.58,
            "multilingual": {
              "mean": 27.21,
              "macro_wer": 28.54,
              "macro_cer": 24.57,
              "coverage": 9,
              "by_language": {
                "pl": 23.75,
                "de": 19.51,
                "fr": 17.82,
                "es": 16.25,
                "sv": 41.72,
                "tr": 52.16,
                "ja": 14.27,
                "zh": 29.42,
                "ko": 30.03
              }
            },
            "speed_x": 34.9,
            "j_per_min": 50.034,
            "energy_note": "median of 3 clean brackets (49.941–50.816 J/min)",
            "memory_mb": 1655,
            "latency_ms": {
              "p50": 0.5,
              "p95": 8.3,
              "n": 15040,
              "kind": "packet",
              "chunk_p50": 7.1,
              "chunk_p95": 9.3
            },
            "disk_mb": 1277,
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "bf16"
              },
              "kernels": [
                "batched_decode",
                "bf16_linears",
                "coalesce",
                "f32_weights",
                "fused_layer",
                "joint_batch",
                "keep_cache",
                "kv_cache",
                "mel_batch",
                "position_cache"
              ],
              "inexact": [
                "bf16_linears",
                "fused_layer",
                "joint_batch"
              ],
              "gate_revision": "native-kernels-10",
              "env": {
                "VELLA_NEMO_KEEPCACHE": "1",
                "VELLA_NEMO_JOINTBATCH": "1"
              }
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "multilingual mean +0.16 pt vs 16 (limit 0.10)",
                "5 clips empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "5 clips empty or cut short where 16 had the words"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_fast"
          }
        },
        "8": {
          "precision": "8b",
          "presence": {
            "offered": true,
            "reasons": []
          },
          "gate": {
            "status": "fail",
            "reasons": [
              "multilingual mean +0.16 pt vs 16 (limit 0.10)"
            ],
            "loss": [
              "multilingual mean +0.16 pt"
            ]
          },
          "standard": {
            "wer": 23.42,
            "format": 10.54,
            "multilingual": {
              "mean": 27.34,
              "macro_wer": 28.68,
              "macro_cer": 24.68,
              "coverage": 9,
              "by_language": {
                "pl": 24.18,
                "de": 18.62,
                "fr": 18.46,
                "es": 16.25,
                "sv": 41.29,
                "tr": 53.27,
                "ja": 14.14,
                "zh": 29.59,
                "ko": 30.3
              }
            },
            "speed_x": 15.1,
            "j_per_min": 112.0,
            "energy_note": "median of 3 clean brackets (110.519–114.841 J/min)",
            "memory_mb": 1191,
            "latency_ms": {
              "p50": 1.5,
              "p95": 18.0,
              "n": 15040,
              "kind": "packet",
              "chunk_p50": 16.6,
              "chunk_p95": 19.0
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": null,
              "performance_suite": "v2-quick"
            },
            "engine": "mlx",
            "recipe": {
              "layers": {
                "all": "affine-8 g64"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "multilingual mean +0.29 pt vs 16 (limit 0.10)",
                "Turkish +2.10 pt vs 16 (limit 2.0)",
                "5 clips empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "5 clips empty or cut short where 16 had the words"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_exact": {
            "wer": 23.42,
            "format": 10.54,
            "multilingual": {
              "mean": 27.34,
              "macro_wer": 28.68,
              "macro_cer": 24.68,
              "coverage": 9,
              "by_language": {
                "pl": 24.18,
                "de": 18.62,
                "fr": 18.46,
                "es": 16.25,
                "sv": 41.29,
                "tr": 53.27,
                "ja": 14.14,
                "zh": 29.59,
                "ko": 30.3
              }
            },
            "speed_x": 29.8,
            "j_per_min": 58.711,
            "energy_note": "median of 3 clean brackets (58.693–58.808 J/min)",
            "memory_mb": 1251,
            "latency_ms": {
              "p50": 0.5,
              "p95": 9.7,
              "n": 15040,
              "kind": "packet",
              "chunk_p50": 8.7,
              "chunk_p95": 10.5
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-8 g64"
              },
              "kernels": [
                "batched_decode",
                "coalesce",
                "f32_weights",
                "keep_cache",
                "kv_cache",
                "mel_batch",
                "position_cache"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {
                "VELLA_NEMO_KEEPCACHE": "1"
              }
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "multilingual mean +0.29 pt vs 16 (limit 0.10)",
                "Turkish +2.10 pt vs 16 (limit 2.0)",
                "5 clips empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "5 clips empty or cut short where 16 had the words"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_fast": {
            "wer": 23.44,
            "format": 10.55,
            "multilingual": {
              "mean": 27.37,
              "macro_wer": 28.72,
              "macro_cer": 24.66,
              "coverage": 9,
              "by_language": {
                "pl": 24.24,
                "de": 18.62,
                "fr": 18.46,
                "es": 16.25,
                "sv": 41.29,
                "tr": 53.49,
                "ja": 14.14,
                "zh": 29.59,
                "ko": 30.26
              }
            },
            "speed_x": 38.4,
            "j_per_min": 43.071,
            "energy_note": "median of 3 clean brackets (30.751–45.524 J/min)",
            "memory_mb": 1114,
            "latency_ms": {
              "p50": 0.5,
              "p95": 7.6,
              "n": 15040,
              "kind": "packet",
              "chunk_p50": 6.4,
              "chunk_p95": 8.6
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-8 g64"
              },
              "kernels": [
                "batched_decode",
                "bf16_linears",
                "coalesce",
                "f32_weights",
                "fused_layer",
                "keep_cache",
                "kv_cache",
                "mel_batch",
                "position_cache"
              ],
              "inexact": [
                "bf16_linears",
                "fused_layer"
              ],
              "gate_revision": "native-kernels-10",
              "env": {
                "VELLA_NEMO_KEEPCACHE": "1"
              }
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "multilingual mean +0.32 pt vs 16 (limit 0.10)",
                "Turkish +2.33 pt vs 16 (limit 2.0)",
                "5 clips empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "5 clips empty or cut short where 16 had the words"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_fast"
          }
        },
        "4": {
          "precision": "4b",
          "presence": {
            "offered": false,
            "reasons": [
              "22 clips empty or cut short where 16 had the words",
              "English WER +9.44 pt vs 16 (presence limit +5.0)",
              "multilingual mean +8.85 pt vs 16 (presence limit +5.0)",
              "Swedish +13.55 pt vs 16 (presence limit +10.0)",
              "Polish +13.09 pt vs 16 (presence limit +10.0)",
              "Turkish +12.29 pt vs 16 (presence limit +10.0)",
              "Japanese +10.46 pt vs 16 (presence limit +10.0)",
              "Chinese +10.23 pt vs 16 (presence limit +10.0)"
            ]
          },
          "gate": {
            "status": "fail",
            "reasons": [
              "English WER +9.44 pt vs 16 (limit 0.10)",
              "multilingual mean +8.85 pt vs 16 (limit 0.10)",
              "Swedish +13.55 pt vs 16 (limit 2.0)",
              "Polish +13.09 pt vs 16 (limit 2.0)",
              "Turkish +12.29 pt vs 16 (limit 2.0)",
              "Japanese +10.46 pt vs 16 (limit 2.0)",
              "Chinese +10.23 pt vs 16 (limit 2.0)",
              "German +8.72 pt vs 16 (limit 2.0)",
              "Korean +4.38 pt vs 16 (limit 2.0)",
              "French +3.66 pt vs 16 (limit 2.0)",
              "Spanish +3.27 pt vs 16 (limit 2.0)",
              "format CER +5.60 pt vs 16 (limit 0.10)",
              "22 clips empty or cut short where 16 had the words (limit 0)"
            ],
            "loss": [
              "English WER +9.44 pt",
              "multilingual mean +8.85 pt",
              "Swedish +13.55 pt",
              "Polish +13.09 pt",
              "Turkish +12.29 pt",
              "Japanese +10.46 pt",
              "Chinese +10.23 pt",
              "German +8.72 pt",
              "Korean +4.38 pt",
              "French +3.66 pt",
              "Spanish +3.27 pt",
              "format CER +5.60 pt"
            ]
          },
          "standard": {
            "wer": 32.78,
            "format": 16.2,
            "multilingual": {
              "mean": 36.08,
              "macro_wer": 37.62,
              "macro_cer": 32.99,
              "coverage": 9,
              "by_language": {
                "pl": 36.85,
                "de": 28.24,
                "fr": 21.4,
                "es": 19.52,
                "sv": 55.27,
                "tr": 64.45,
                "ja": 24.6,
                "zh": 39.94,
                "ko": 34.42
              }
            },
            "speed_x": 15.3,
            "j_per_min": 110.168,
            "energy_note": "median of 3 clean brackets (106.051–110.664 J/min)",
            "memory_mb": 927,
            "latency_ms": {
              "p50": 1.5,
              "p95": 17.7,
              "n": 15040,
              "kind": "packet",
              "chunk_p50": 16.3,
              "chunk_p95": 18.7
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": null,
              "performance_suite": "v2-quick"
            },
            "engine": "mlx",
            "recipe": {
              "layers": {
                "all": "affine-4 g64"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +9.28 pt vs 16 (limit 0.10)",
                "multilingual mean +9.02 pt vs 16 (limit 0.10)",
                "Swedish +15.05 pt vs 16 (limit 2.0)",
                "Turkish +13.29 pt vs 16 (limit 2.0)",
                "Polish +11.51 pt vs 16 (limit 2.0)",
                "Chinese +10.94 pt vs 16 (limit 2.0)",
                "German +10.25 pt vs 16 (limit 2.0)",
                "Japanese +9.13 pt vs 16 (limit 2.0)",
                "Korean +3.93 pt vs 16 (limit 2.0)",
                "French +3.58 pt vs 16 (limit 2.0)",
                "Spanish +3.53 pt vs 16 (limit 2.0)",
                "format CER +5.31 pt vs 16 (limit 0.10)",
                "22 clips empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "22 clips empty or cut short where 16 had the words",
                  "English WER +9.28 pt vs 16 (presence limit +5.0)",
                  "multilingual mean +9.02 pt vs 16 (presence limit +5.0)",
                  "Swedish +15.05 pt vs 16 (presence limit +10.0)",
                  "Turkish +13.29 pt vs 16 (presence limit +10.0)",
                  "Polish +11.51 pt vs 16 (presence limit +10.0)",
                  "Chinese +10.94 pt vs 16 (presence limit +10.0)",
                  "German +10.25 pt vs 16 (presence limit +10.0)"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_exact": {
            "wer": 32.78,
            "format": 16.2,
            "multilingual": {
              "mean": 36.08,
              "macro_wer": 37.62,
              "macro_cer": 32.99,
              "coverage": 9,
              "by_language": {
                "pl": 36.85,
                "de": 28.24,
                "fr": 21.4,
                "es": 19.52,
                "sv": 55.27,
                "tr": 64.45,
                "ja": 24.6,
                "zh": 39.94,
                "ko": 34.42
              }
            },
            "speed_x": 30.4,
            "j_per_min": 55.568,
            "energy_note": "median of 3 clean brackets (55.332–56.020 J/min)",
            "memory_mb": 980,
            "latency_ms": {
              "p50": 0.5,
              "p95": 9.4,
              "n": 15040,
              "kind": "packet",
              "chunk_p50": 8.5,
              "chunk_p95": 10.1
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-4 g64"
              },
              "kernels": [
                "batched_decode",
                "coalesce",
                "f32_weights",
                "keep_cache",
                "kv_cache",
                "mel_batch",
                "position_cache"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {
                "VELLA_NEMO_KEEPCACHE": "1"
              }
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +9.28 pt vs 16 (limit 0.10)",
                "multilingual mean +9.02 pt vs 16 (limit 0.10)",
                "Swedish +15.05 pt vs 16 (limit 2.0)",
                "Turkish +13.29 pt vs 16 (limit 2.0)",
                "Polish +11.51 pt vs 16 (limit 2.0)",
                "Chinese +10.94 pt vs 16 (limit 2.0)",
                "German +10.25 pt vs 16 (limit 2.0)",
                "Japanese +9.13 pt vs 16 (limit 2.0)",
                "Korean +3.93 pt vs 16 (limit 2.0)",
                "French +3.58 pt vs 16 (limit 2.0)",
                "Spanish +3.53 pt vs 16 (limit 2.0)",
                "format CER +5.31 pt vs 16 (limit 0.10)",
                "22 clips empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "22 clips empty or cut short where 16 had the words",
                  "English WER +9.28 pt vs 16 (presence limit +5.0)",
                  "multilingual mean +9.02 pt vs 16 (presence limit +5.0)",
                  "Swedish +15.05 pt vs 16 (presence limit +10.0)",
                  "Turkish +13.29 pt vs 16 (presence limit +10.0)",
                  "Polish +11.51 pt vs 16 (presence limit +10.0)",
                  "Chinese +10.94 pt vs 16 (presence limit +10.0)",
                  "German +10.25 pt vs 16 (presence limit +10.0)"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_fast": {
            "wer": 32.8,
            "format": 16.18,
            "multilingual": {
              "mean": 36.07,
              "macro_wer": 37.63,
              "macro_cer": 32.93,
              "coverage": 9,
              "by_language": {
                "pl": 36.85,
                "de": 28.24,
                "fr": 21.48,
                "es": 19.52,
                "sv": 55.27,
                "tr": 64.45,
                "ja": 24.73,
                "zh": 39.65,
                "ko": 34.42
              }
            },
            "speed_x": 39.7,
            "j_per_min": 39.768,
            "energy_note": "median of 3 clean brackets (39.155–40.386 J/min)",
            "memory_mb": 847,
            "latency_ms": {
              "p50": 0.5,
              "p95": 7.3,
              "n": 15040,
              "kind": "packet",
              "chunk_p50": 6.1,
              "chunk_p95": 8.3
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-4 g64"
              },
              "kernels": [
                "batched_decode",
                "bf16_linears",
                "coalesce",
                "f32_weights",
                "fused_layer",
                "keep_cache",
                "kv_cache",
                "mel_batch",
                "position_cache"
              ],
              "inexact": [
                "bf16_linears",
                "fused_layer"
              ],
              "gate_revision": "native-kernels-10",
              "env": {
                "VELLA_NEMO_KEEPCACHE": "1"
              }
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +9.29 pt vs 16 (limit 0.10)",
                "multilingual mean +9.01 pt vs 16 (limit 0.10)",
                "Swedish +15.05 pt vs 16 (limit 2.0)",
                "Turkish +13.29 pt vs 16 (limit 2.0)",
                "Polish +11.51 pt vs 16 (limit 2.0)",
                "Chinese +10.64 pt vs 16 (limit 2.0)",
                "German +10.25 pt vs 16 (limit 2.0)",
                "Japanese +9.26 pt vs 16 (limit 2.0)",
                "Korean +3.93 pt vs 16 (limit 2.0)",
                "French +3.66 pt vs 16 (limit 2.0)",
                "Spanish +3.53 pt vs 16 (limit 2.0)",
                "format CER +5.29 pt vs 16 (limit 0.10)",
                "22 clips empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "22 clips empty or cut short where 16 had the words",
                  "English WER +9.29 pt vs 16 (presence limit +5.0)",
                  "multilingual mean +9.01 pt vs 16 (presence limit +5.0)",
                  "Swedish +15.05 pt vs 16 (presence limit +10.0)",
                  "Turkish +13.29 pt vs 16 (presence limit +10.0)",
                  "Polish +11.51 pt vs 16 (presence limit +10.0)",
                  "Chinese +10.64 pt vs 16 (presence limit +10.0)",
                  "German +10.25 pt vs 16 (presence limit +10.0)"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_fast"
          }
        }
      }
    },
    "parakeet-v3-ultra": {
      "noise_pt": 0.02,
      "tolerance_pt": 0.1,
      "noise_ml_pt": 0.0,
      "tolerance_ml_pt": 0.1,
      "tiers": {
        "16": {
          "precision": "BF16",
          "presence": {
            "offered": true,
            "reasons": []
          },
          "gate": {
            "status": "pass",
            "reasons": [],
            "loss": []
          },
          "standard": {
            "wer": 15.46,
            "format": 5.8,
            "multilingual": {
              "mean": 12.72,
              "macro_wer": 12.72,
              "macro_cer": null,
              "coverage": 5,
              "by_language": {
                "pl": 7.0,
                "de": 8.54,
                "fr": 16.55,
                "es": 13.67,
                "sv": 17.85
              }
            },
            "speed_x": 261.4,
            "j_per_min": 6.328,
            "energy_note": "median of 3 clean brackets (6.301–6.336 J/min)",
            "memory_mb": 1796,
            "latency_ms": {
              "p50": 24.3,
              "p95": 48.5,
              "n": 188,
              "kind": "segment"
            },
            "disk_mb": 1255,
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": null,
              "performance_suite": "v2-quick"
            },
            "engine": "mlx",
            "recipe": {
              "layers": {
                "all": "bf16"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "pass",
              "reasons": [],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_exact": {
            "wer": 15.49,
            "format": 5.74,
            "multilingual": {
              "mean": 12.65,
              "macro_wer": 12.65,
              "macro_cer": null,
              "coverage": 5,
              "by_language": {
                "pl": 6.82,
                "de": 8.54,
                "fr": 16.47,
                "es": 13.59,
                "sv": 17.85
              }
            },
            "speed_x": 474.5,
            "j_per_min": 4.706,
            "energy_note": "median of 3 clean brackets (4.700–4.733 J/min)",
            "memory_mb": 1808,
            "latency_ms": {
              "p50": 14.0,
              "p95": 21.0,
              "n": 188,
              "kind": "segment"
            },
            "disk_mb": 1255,
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "bf16"
              },
              "kernels": [
                "decoder",
                "encoder"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {
                "VELLA_PARAKEET_TAILBLOCK": "1"
              }
            },
            "gate": {
              "status": "pass",
              "reasons": [],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_fast": {
            "wer": 15.51,
            "format": 5.79,
            "multilingual": {
              "mean": 12.73,
              "macro_wer": 12.73,
              "macro_cer": null,
              "coverage": 5,
              "by_language": {
                "pl": 6.88,
                "de": 8.72,
                "fr": 16.55,
                "es": 13.67,
                "sv": 17.85
              }
            },
            "speed_x": 507.1,
            "j_per_min": 4.582,
            "energy_note": "median of 3 clean brackets (4.421–4.638 J/min)",
            "memory_mb": 1792,
            "latency_ms": {
              "p50": 12.9,
              "p95": 21.2,
              "n": 188,
              "kind": "segment"
            },
            "disk_mb": 1255,
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "bf16"
              },
              "kernels": [
                "decoder",
                "encoder",
                "nax_gemm"
              ],
              "inexact": [
                "nax_gemm"
              ],
              "gate_revision": "native-kernels-10",
              "env": {
                "VELLA_PARAKEET_TAILBLOCK": "1"
              }
            },
            "gate": {
              "status": "pass",
              "reasons": [],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_fast"
          }
        },
        "8": {
          "precision": "8b",
          "presence": {
            "offered": true,
            "reasons": []
          },
          "gate": {
            "status": "fail",
            "reasons": [
              "multilingual mean +0.23 pt vs 16 (limit 0.10)"
            ],
            "loss": [
              "multilingual mean +0.23 pt"
            ]
          },
          "standard": {
            "wer": 15.46,
            "format": 5.76,
            "multilingual": {
              "mean": 12.84,
              "macro_wer": 12.83,
              "macro_cer": null,
              "coverage": 5,
              "by_language": {
                "pl": 7.13,
                "de": 8.63,
                "fr": 16.55,
                "es": 13.59,
                "sv": 18.28
              }
            },
            "speed_x": 244.8,
            "j_per_min": 8.995,
            "energy_note": "median of 3 clean brackets (8.994–9.029 J/min)",
            "memory_mb": 1280,
            "latency_ms": {
              "p50": 25.7,
              "p95": 53.0,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": null,
              "performance_suite": "v2-quick"
            },
            "engine": "mlx",
            "recipe": {
              "layers": {
                "all": "affine-8 g64",
                "decoder": "bf16",
                "joint": "bf16"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "multilingual mean +0.11 pt vs 16 (limit 0.10)"
              ],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_exact": {
            "wer": 15.46,
            "format": 5.77,
            "multilingual": {
              "mean": 12.86,
              "macro_wer": 12.86,
              "macro_cer": null,
              "coverage": 5,
              "by_language": {
                "pl": 6.94,
                "de": 8.81,
                "fr": 16.55,
                "es": 13.5,
                "sv": 18.49
              }
            },
            "speed_x": 369.0,
            "j_per_min": 8.62,
            "energy_note": "median of 3 clean brackets (8.607–8.644 J/min)",
            "memory_mb": 1888,
            "latency_ms": {
              "p50": 17.8,
              "p95": 27.9,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-8 g64",
                "decoder": "bf16",
                "joint": "bf16"
              },
              "kernels": [
                "decoder",
                "encoder"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {
                "VELLA_PARAKEET_TAILBLOCK": "1"
              }
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "multilingual mean +0.14 pt vs 16 (limit 0.10)"
              ],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_fast": {
            "wer": 15.46,
            "format": 5.81,
            "multilingual": {
              "mean": 12.96,
              "macro_wer": 12.96,
              "macro_cer": null,
              "coverage": 5,
              "by_language": {
                "pl": 7.19,
                "de": 8.54,
                "fr": 16.79,
                "es": 13.59,
                "sv": 18.71
              }
            },
            "speed_x": 515.0,
            "j_per_min": 5.349,
            "energy_note": "median of 3 clean brackets (5.330–5.392 J/min)",
            "memory_mb": 1352,
            "latency_ms": {
              "p50": 12.9,
              "p95": 21.1,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-8 g64",
                "decoder": "bf16",
                "joint": "bf16"
              },
              "kernels": [
                "decoder",
                "encoder",
                "int8_gemm"
              ],
              "inexact": [
                "int8_gemm"
              ],
              "gate_revision": "native-kernels-10",
              "env": {
                "VELLA_PARAKEET_INT8": "1",
                "VELLA_PARAKEET_TAILBLOCK": "1"
              }
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "multilingual mean +0.24 pt vs 16 (limit 0.10)"
              ],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_fast"
          }
        },
        "4": {
          "precision": "4b",
          "presence": {
            "offered": true,
            "reasons": []
          },
          "gate": {
            "status": "fail",
            "reasons": [
              "multilingual mean +0.79 pt vs 16 (limit 0.10)",
              "Swedish +2.37 pt vs 16 (limit 2.0)"
            ],
            "loss": [
              "multilingual mean +0.79 pt",
              "Swedish +2.37 pt"
            ]
          },
          "standard": {
            "wer": 15.62,
            "format": 5.81,
            "multilingual": {
              "mean": 13.66,
              "macro_wer": 13.66,
              "macro_cer": null,
              "coverage": 5,
              "by_language": {
                "pl": 7.49,
                "de": 8.72,
                "fr": 16.95,
                "es": 14.27,
                "sv": 20.86
              }
            },
            "speed_x": 246.7,
            "j_per_min": 8.75,
            "energy_note": "median of 3 clean brackets (8.740–8.845 J/min)",
            "memory_mb": 1024,
            "latency_ms": {
              "p50": 25.5,
              "p95": 52.3,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": null,
              "performance_suite": "v2-quick"
            },
            "engine": "mlx",
            "recipe": {
              "layers": {
                "all": "affine-4 g64",
                "decoder": "bf16",
                "joint": "bf16"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +0.16 pt vs 16 (limit 0.10)",
                "multilingual mean +0.94 pt vs 16 (limit 0.10)",
                "Swedish +3.01 pt vs 16 (limit 2.0)"
              ],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_exact": {
            "wer": 15.65,
            "format": 5.84,
            "multilingual": {
              "mean": 13.6,
              "macro_wer": 13.6,
              "macro_cer": null,
              "coverage": 5,
              "by_language": {
                "pl": 7.43,
                "de": 8.72,
                "fr": 16.95,
                "es": 14.27,
                "sv": 20.65
              }
            },
            "speed_x": 370.6,
            "j_per_min": 8.413,
            "energy_note": "median of 3 clean brackets (8.376–8.421 J/min)",
            "memory_mb": 1640,
            "latency_ms": {
              "p50": 17.8,
              "p95": 28.0,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-4 g64",
                "decoder": "bf16",
                "joint": "bf16"
              },
              "kernels": [
                "decoder",
                "encoder"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {
                "VELLA_PARAKEET_TAILBLOCK": "1"
              }
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +0.19 pt vs 16 (limit 0.10)",
                "multilingual mean +0.88 pt vs 16 (limit 0.10)",
                "Swedish +2.80 pt vs 16 (limit 2.0)"
              ],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_fast": {
            "wer": 15.58,
            "format": 5.8,
            "multilingual": {
              "mean": 13.53,
              "macro_wer": 13.53,
              "macro_cer": null,
              "coverage": 5,
              "by_language": {
                "pl": 7.55,
                "de": 8.72,
                "fr": 16.79,
                "es": 14.36,
                "sv": 20.22
              }
            },
            "speed_x": 522.5,
            "j_per_min": 5.129,
            "energy_note": "median of 3 clean brackets (5.123–5.133 J/min)",
            "memory_mb": 1094,
            "latency_ms": {
              "p50": 12.8,
              "p95": 21.0,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-4 g64",
                "decoder": "bf16",
                "joint": "bf16"
              },
              "kernels": [
                "decoder",
                "encoder",
                "int4_gemm"
              ],
              "inexact": [
                "int4_gemm"
              ],
              "gate_revision": "native-kernels-10",
              "env": {
                "VELLA_PARAKEET_INT4": "1",
                "VELLA_PARAKEET_TAILBLOCK": "1"
              }
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +0.11 pt vs 16 (limit 0.10)",
                "multilingual mean +0.80 pt vs 16 (limit 0.10)",
                "Swedish +2.37 pt vs 16 (limit 2.0)"
              ],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_fast"
          }
        }
      }
    },
    "qwen3-asr-0.6b": {
      "noise_pt": 0.0,
      "tolerance_pt": 0.1,
      "noise_ml_pt": 0.0,
      "tolerance_ml_pt": 0.1,
      "tiers": {
        "16": {
          "precision": "BF16",
          "presence": {
            "offered": true,
            "reasons": []
          },
          "gate": {
            "status": "pass",
            "reasons": [],
            "loss": []
          },
          "standard": {
            "wer": 15.89,
            "format": 7.16,
            "multilingual": {
              "mean": 20.14,
              "macro_wer": 24.03,
              "macro_cer": 12.36,
              "coverage": 9,
              "by_language": {
                "pl": 25.52,
                "de": 15.47,
                "fr": 16.23,
                "es": 13.07,
                "sv": 47.1,
                "tr": 26.8,
                "ja": 5.96,
                "zh": 14.68,
                "ko": 16.43
              }
            },
            "speed_x": 51.7,
            "j_per_min": 36.823,
            "energy_note": "median of 3 clean brackets (36.696–36.897 J/min)",
            "memory_mb": 2142,
            "latency_ms": {
              "p50": 118.5,
              "p95": 290.3,
              "n": 188,
              "kind": "segment"
            },
            "disk_mb": 1569,
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": null,
              "performance_suite": "v2-quick"
            },
            "engine": "mlx",
            "recipe": {
              "layers": {
                "all": "bf16"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "pass",
              "reasons": [],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_exact": {
            "wer": 15.89,
            "format": 7.16,
            "multilingual": {
              "mean": 20.14,
              "macro_wer": 24.03,
              "macro_cer": 12.36,
              "coverage": 9,
              "by_language": {
                "pl": 25.52,
                "de": 15.47,
                "fr": 16.23,
                "es": 13.07,
                "sv": 47.1,
                "tr": 26.8,
                "ja": 5.96,
                "zh": 14.68,
                "ko": 16.43
              }
            },
            "speed_x": 64.4,
            "j_per_min": 34.071,
            "energy_note": "median of 3 clean brackets (34.051–34.140 J/min)",
            "memory_mb": 2406,
            "latency_ms": {
              "p50": 95.5,
              "p95": 234.3,
              "n": 188,
              "kind": "segment"
            },
            "disk_mb": 1569,
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "bf16"
              },
              "kernels": [
                "decoder",
                "encoder"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {}
            },
            "gate": {
              "status": "pass",
              "reasons": [],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_fast": {
            "wer": 15.89,
            "format": 7.16,
            "multilingual": {
              "mean": 20.14,
              "macro_wer": 24.03,
              "macro_cer": 12.36,
              "coverage": 9,
              "by_language": {
                "pl": 25.52,
                "de": 15.47,
                "fr": 16.23,
                "es": 13.07,
                "sv": 47.1,
                "tr": 26.8,
                "ja": 5.96,
                "zh": 14.68,
                "ko": 16.43
              }
            },
            "speed_x": 63.2,
            "j_per_min": 34.724,
            "energy_note": "median of 3 clean brackets (34.714–34.822 J/min)",
            "memory_mb": 2352,
            "latency_ms": {
              "p50": 97.0,
              "p95": 238.1,
              "n": 188,
              "kind": "segment"
            },
            "disk_mb": 1569,
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "bf16"
              },
              "kernels": [
                "decoder",
                "encoder"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {}
            },
            "gate": {
              "status": "pass",
              "reasons": [],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_exact"
          }
        },
        "8": {
          "precision": "8b",
          "presence": {
            "offered": true,
            "reasons": []
          },
          "gate": {
            "status": "fail",
            "reasons": [
              "English WER +0.15 pt vs 16 (limit 0.10)",
              "multilingual mean +0.32 pt vs 16 (limit 0.10)"
            ],
            "loss": [
              "English WER +0.15 pt",
              "multilingual mean +0.32 pt"
            ]
          },
          "standard": {
            "wer": 16.04,
            "format": 7.17,
            "multilingual": {
              "mean": 20.46,
              "macro_wer": 24.38,
              "macro_cer": 12.61,
              "coverage": 9,
              "by_language": {
                "pl": 25.4,
                "de": 15.74,
                "fr": 16.23,
                "es": 13.5,
                "sv": 47.53,
                "tr": 27.91,
                "ja": 6.02,
                "zh": 15.15,
                "ko": 16.66
              }
            },
            "speed_x": 60.7,
            "j_per_min": 33.577,
            "energy_note": "median of 3 clean brackets (33.569–33.599 J/min)",
            "memory_mb": 1639,
            "latency_ms": {
              "p50": 100.2,
              "p95": 243.1,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": null,
              "performance_suite": "v2-quick"
            },
            "engine": "mlx",
            "recipe": {
              "layers": {
                "all": "affine-8 g64"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +0.15 pt vs 16 (limit 0.10)",
                "multilingual mean +0.32 pt vs 16 (limit 0.10)"
              ],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_exact": {
            "wer": 16.04,
            "format": 7.17,
            "multilingual": {
              "mean": 20.46,
              "macro_wer": 24.38,
              "macro_cer": 12.61,
              "coverage": 9,
              "by_language": {
                "pl": 25.4,
                "de": 15.74,
                "fr": 16.23,
                "es": 13.5,
                "sv": 47.53,
                "tr": 27.91,
                "ja": 6.02,
                "zh": 15.15,
                "ko": 16.66
              }
            },
            "speed_x": 82.0,
            "j_per_min": 30.055,
            "energy_note": "median of 3 clean brackets (30.003–30.075 J/min)",
            "memory_mb": 1920,
            "latency_ms": {
              "p50": 74.4,
              "p95": 180.4,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-8 g64"
              },
              "kernels": [
                "decoder",
                "encoder"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +0.15 pt vs 16 (limit 0.10)",
                "multilingual mean +0.32 pt vs 16 (limit 0.10)"
              ],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_fast": {
            "wer": 16.04,
            "format": 7.17,
            "multilingual": {
              "mean": 20.46,
              "macro_wer": 24.38,
              "macro_cer": 12.61,
              "coverage": 9,
              "by_language": {
                "pl": 25.4,
                "de": 15.74,
                "fr": 16.23,
                "es": 13.5,
                "sv": 47.53,
                "tr": 27.91,
                "ja": 6.02,
                "zh": 15.15,
                "ko": 16.66
              }
            },
            "speed_x": 82.0,
            "j_per_min": 30.083,
            "energy_note": "median of 3 clean brackets (30.060–30.164 J/min)",
            "memory_mb": 1934,
            "latency_ms": {
              "p50": 74.5,
              "p95": 180.5,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-8 g64"
              },
              "kernels": [
                "decoder",
                "encoder"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +0.15 pt vs 16 (limit 0.10)",
                "multilingual mean +0.32 pt vs 16 (limit 0.10)"
              ],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_exact"
          }
        },
        "4": {
          "precision": "4b",
          "presence": {
            "offered": false,
            "reasons": [
              "2 clips empty or cut short where 16 had the words"
            ]
          },
          "gate": {
            "status": "fail",
            "reasons": [
              "English WER +1.67 pt vs 16 (limit 0.10)",
              "multilingual mean +4.79 pt vs 16 (limit 0.10)",
              "Swedish +7.74 pt vs 16 (limit 2.0)",
              "Polish +7.67 pt vs 16 (limit 2.0)",
              "Spanish +5.93 pt vs 16 (limit 2.0)",
              "Japanese +5.90 pt vs 16 (limit 2.0)",
              "Turkish +5.76 pt vs 16 (limit 2.0)",
              "French +3.82 pt vs 16 (limit 2.0)",
              "Korean +2.38 pt vs 16 (limit 2.0)",
              "German +2.07 pt vs 16 (limit 2.0)",
              "format CER +1.09 pt vs 16 (limit 0.10)",
              "2 clips empty or cut short where 16 had the words (limit 0)"
            ],
            "loss": [
              "English WER +1.67 pt",
              "multilingual mean +4.79 pt",
              "Swedish +7.74 pt",
              "Polish +7.67 pt",
              "Spanish +5.93 pt",
              "Japanese +5.90 pt",
              "Turkish +5.76 pt",
              "French +3.82 pt",
              "Korean +2.38 pt",
              "German +2.07 pt",
              "format CER +1.09 pt"
            ]
          },
          "standard": {
            "wer": 17.56,
            "format": 8.25,
            "multilingual": {
              "mean": 24.93,
              "macro_wer": 29.53,
              "macro_cer": 15.72,
              "coverage": 9,
              "by_language": {
                "pl": 33.19,
                "de": 17.54,
                "fr": 20.05,
                "es": 19.0,
                "sv": 54.84,
                "tr": 32.56,
                "ja": 11.86,
                "zh": 16.49,
                "ko": 18.81
              }
            },
            "speed_x": 68.4,
            "j_per_min": 28.713,
            "energy_note": "median of 3 clean brackets (28.712–28.776 J/min)",
            "memory_mb": 1332,
            "latency_ms": {
              "p50": 89.0,
              "p95": 213.0,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": null,
              "performance_suite": "v2-quick"
            },
            "engine": "mlx",
            "recipe": {
              "layers": {
                "all": "affine-4 g64"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +1.67 pt vs 16 (limit 0.10)",
                "multilingual mean +4.79 pt vs 16 (limit 0.10)",
                "Swedish +7.74 pt vs 16 (limit 2.0)",
                "Polish +7.67 pt vs 16 (limit 2.0)",
                "Spanish +5.93 pt vs 16 (limit 2.0)",
                "Japanese +5.90 pt vs 16 (limit 2.0)",
                "Turkish +5.76 pt vs 16 (limit 2.0)",
                "French +3.82 pt vs 16 (limit 2.0)",
                "Korean +2.38 pt vs 16 (limit 2.0)",
                "German +2.07 pt vs 16 (limit 2.0)",
                "format CER +1.09 pt vs 16 (limit 0.10)",
                "2 clips empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "2 clips empty or cut short where 16 had the words"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_exact": {
            "wer": 17.56,
            "format": 8.25,
            "multilingual": {
              "mean": 24.93,
              "macro_wer": 29.53,
              "macro_cer": 15.72,
              "coverage": 9,
              "by_language": {
                "pl": 33.19,
                "de": 17.54,
                "fr": 20.05,
                "es": 19.0,
                "sv": 54.84,
                "tr": 32.56,
                "ja": 11.86,
                "zh": 16.49,
                "ko": 18.81
              }
            },
            "speed_x": 96.4,
            "j_per_min": 25.601,
            "energy_note": "median of 3 clean brackets (25.577–25.616 J/min)",
            "memory_mb": 1648,
            "latency_ms": {
              "p50": 63.3,
              "p95": 151.5,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-4 g64"
              },
              "kernels": [
                "decoder",
                "encoder"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +1.67 pt vs 16 (limit 0.10)",
                "multilingual mean +4.79 pt vs 16 (limit 0.10)",
                "Swedish +7.74 pt vs 16 (limit 2.0)",
                "Polish +7.67 pt vs 16 (limit 2.0)",
                "Spanish +5.93 pt vs 16 (limit 2.0)",
                "Japanese +5.90 pt vs 16 (limit 2.0)",
                "Turkish +5.76 pt vs 16 (limit 2.0)",
                "French +3.82 pt vs 16 (limit 2.0)",
                "Korean +2.38 pt vs 16 (limit 2.0)",
                "German +2.07 pt vs 16 (limit 2.0)",
                "format CER +1.09 pt vs 16 (limit 0.10)",
                "2 clips empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "2 clips empty or cut short where 16 had the words"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "optimized_fast": {
            "wer": 17.56,
            "format": 8.25,
            "multilingual": {
              "mean": 24.93,
              "macro_wer": 29.53,
              "macro_cer": 15.72,
              "coverage": 9,
              "by_language": {
                "pl": 33.19,
                "de": 17.54,
                "fr": 20.05,
                "es": 19.0,
                "sv": 54.84,
                "tr": 32.56,
                "ja": 11.86,
                "zh": 16.49,
                "ko": 18.81
              }
            },
            "speed_x": 96.5,
            "j_per_min": 25.49,
            "energy_note": "median of 3 clean brackets (25.458–25.868 J/min)",
            "memory_mb": 1648,
            "latency_ms": {
              "p50": 63.1,
              "p95": 151.3,
              "n": 188,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-4 g64"
              },
              "kernels": [
                "decoder",
                "encoder"
              ],
              "inexact": [],
              "gate_revision": "native-kernels-10",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +1.67 pt vs 16 (limit 0.10)",
                "multilingual mean +4.79 pt vs 16 (limit 0.10)",
                "Swedish +7.74 pt vs 16 (limit 2.0)",
                "Polish +7.67 pt vs 16 (limit 2.0)",
                "Spanish +5.93 pt vs 16 (limit 2.0)",
                "Japanese +5.90 pt vs 16 (limit 2.0)",
                "Turkish +5.76 pt vs 16 (limit 2.0)",
                "French +3.82 pt vs 16 (limit 2.0)",
                "Korean +2.38 pt vs 16 (limit 2.0)",
                "German +2.07 pt vs 16 (limit 2.0)",
                "format CER +1.09 pt vs 16 (limit 0.10)",
                "2 clips empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "2 clips empty or cut short where 16 had the words"
                ]
              },
              "baseline": "tier16 Standard (same final build)"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_exact"
          }
        }
      }
    },
    "whisper-large-v3": {
      "tolerance_pt": 0.1,
      "tolerance_ml_pt": 0.1,
      "tiers": {
        "16": {
          "precision": "FP16",
          "presence": {
            "offered": true,
            "reasons": [],
            "baseline": "tier16 Optimized Fast (measured)"
          },
          "gate": {
            "status": "pass",
            "reasons": [],
            "loss": [],
            "baseline": "tier16 Optimized Fast (measured)"
          },
          "standard": {
            "wer": null,
            "format": null,
            "multilingual": null,
            "speed_x": null,
            "j_per_min": null,
            "energy_note": null,
            "memory_mb": null,
            "latency_ms": null,
            "disk_mb": null,
            "measured": null,
            "engine": null,
            "recipe": {
              "layers": {
                "all": "fp16"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "withdrawn",
              "reasons": [
                "Standard now computes in FP16 like mlx-whisper; the earlier Float32 Standard figures were withdrawn and this cell will be measured after 2.0."
              ],
              "baseline": "tier16 withdrawn Float32 Standard (measured build 55cb080, built from 77be9f2); not the shipped FP16 Standard"
            },
            "build_provenance": {
              "measured": null,
              "recipe": "builds.shipped",
              "bridge": "builds.bridge",
              "withdrawn_from": "builds.measured"
            },
            "not_measured_reason": "Standard now computes in FP16 like mlx-whisper; the earlier Float32 Standard figures were withdrawn and this cell will be measured after 2.0."
          },
          "optimized_exact": {
            "wer": null,
            "format": null,
            "multilingual": null,
            "speed_x": null,
            "j_per_min": null,
            "energy_note": null,
            "memory_mb": null,
            "latency_ms": null,
            "disk_mb": null,
            "measured": null,
            "engine": null,
            "recipe": {
              "layers": {
                "all": "fp16"
              },
              "kernels": [
                "decoder"
              ],
              "inexact": [],
              "gate_revision": "whisper-4",
              "env": {}
            },
            "gate": {
              "status": "withdrawn",
              "reasons": [
                "Exact now equals Fast for Whisper; not measured separately yet."
              ],
              "baseline": "tier16 withdrawn Float32 Standard (measured build 55cb080, built from 77be9f2); not the shipped FP16 Standard"
            },
            "build_provenance": {
              "measured": null,
              "recipe": "builds.shipped",
              "bridge": "builds.bridge",
              "withdrawn_from": "builds.measured"
            },
            "not_measured_reason": "Exact now equals Fast for Whisper; not measured separately yet."
          },
          "optimized_fast": {
            "wer": 17.06,
            "format": 8.17,
            "multilingual": {
              "mean": 14.53,
              "macro_wer": 13.92,
              "macro_cer": 15.76,
              "coverage": 9,
              "by_language": {
                "pl": 6.7,
                "de": 8.18,
                "fr": 22.04,
                "es": 17.2,
                "sv": 16.77,
                "tr": 12.62,
                "ja": 3.74,
                "zh": 21.11,
                "ko": 22.44
              }
            },
            "speed_x": 34.8,
            "j_per_min": 83.501,
            "energy_note": "median of 3 clean brackets (83.495–86.962 J/min)",
            "memory_mb": 3915,
            "latency_ms": {
              "p50": 222.0,
              "p95": 482.9,
              "n": 133,
              "kind": "segment"
            },
            "disk_mb": 3088,
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-02",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "fp16"
              },
              "kernels": [
                "decoder"
              ],
              "inexact": [],
              "gate_revision": "whisper-4",
              "env": {}
            },
            "gate": {
              "status": "pass",
              "reasons": [],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 withdrawn Float32 Standard (measured build 55cb080, built from 77be9f2); not the shipped FP16 Standard"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_fast"
          }
        },
        "8": {
          "precision": "8b",
          "presence": {
            "offered": true,
            "reasons": [],
            "baseline": "tier16 Optimized Fast (measured)"
          },
          "gate": {
            "status": "fail",
            "reasons": [
              "English WER +0.22 pt vs 16 (limit 0.10)"
            ],
            "loss": [
              "English WER +0.22 pt"
            ],
            "baseline": "tier16 Optimized Fast (measured)"
          },
          "standard": {
            "wer": null,
            "format": null,
            "multilingual": null,
            "speed_x": null,
            "j_per_min": null,
            "energy_note": null,
            "memory_mb": null,
            "latency_ms": null,
            "measured": null,
            "engine": null,
            "recipe": {
              "layers": {
                "all": "affine-8 g64",
                "model.encoder": "fp16"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "withdrawn",
              "reasons": [
                "Standard now computes in FP16 like mlx-whisper; the earlier Float32 Standard figures were withdrawn and this cell will be measured after 2.0."
              ],
              "baseline": "tier16 withdrawn Float32 Standard (measured build 55cb080, built from 77be9f2); not the shipped FP16 Standard"
            },
            "build_provenance": {
              "measured": null,
              "recipe": "builds.shipped",
              "bridge": "builds.bridge",
              "withdrawn_from": "builds.measured"
            },
            "not_measured_reason": "Standard now computes in FP16 like mlx-whisper; the earlier Float32 Standard figures were withdrawn and this cell will be measured after 2.0."
          },
          "optimized_exact": {
            "wer": null,
            "format": null,
            "multilingual": null,
            "speed_x": null,
            "j_per_min": null,
            "energy_note": null,
            "memory_mb": null,
            "latency_ms": null,
            "measured": null,
            "engine": null,
            "recipe": {
              "layers": {
                "all": "affine-8 g64",
                "model.encoder": "fp16"
              },
              "kernels": [
                "decoder",
                "fused_decode"
              ],
              "inexact": [],
              "gate_revision": "whisper-4",
              "env": {}
            },
            "gate": {
              "status": "withdrawn",
              "reasons": [
                "Exact now equals Fast for Whisper; not measured separately yet."
              ],
              "baseline": "tier16 withdrawn Float32 Standard (measured build 55cb080, built from 77be9f2); not the shipped FP16 Standard"
            },
            "build_provenance": {
              "measured": null,
              "recipe": "builds.shipped",
              "bridge": "builds.bridge",
              "withdrawn_from": "builds.measured"
            },
            "not_measured_reason": "Exact now equals Fast for Whisper; not measured separately yet."
          },
          "optimized_fast": {
            "wer": 17.27,
            "format": 8.18,
            "multilingual": {
              "mean": 14.57,
              "macro_wer": 13.92,
              "macro_cer": 15.86,
              "coverage": 9,
              "by_language": {
                "pl": 6.7,
                "de": 8.18,
                "fr": 22.04,
                "es": 17.11,
                "sv": 16.77,
                "tr": 12.74,
                "ja": 3.74,
                "zh": 21.46,
                "ko": 22.36
              }
            },
            "speed_x": 42.9,
            "j_per_min": 75.222,
            "energy_note": "median of 3 clean brackets (75.143–75.269 J/min)",
            "memory_mb": 3104,
            "latency_ms": {
              "p50": 181.8,
              "p95": 372.1,
              "n": 133,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-8 g64",
                "model.encoder": "fp16"
              },
              "kernels": [
                "decoder",
                "fused_decode"
              ],
              "inexact": [],
              "gate_revision": "whisper-4",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +0.27 pt vs 16 (limit 0.10)"
              ],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 withdrawn Float32 Standard (measured build 55cb080, built from 77be9f2); not the shipped FP16 Standard"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_fast"
          }
        },
        "4": {
          "precision": "4b",
          "presence": {
            "offered": false,
            "reasons": [
              "2 clips empty or cut short where 16 had the words"
            ],
            "baseline": "tier16 Optimized Fast (measured)"
          },
          "gate": {
            "status": "fail",
            "reasons": [
              "2 clips empty or cut short where 16 had the words (limit 0)"
            ],
            "loss": [],
            "baseline": "tier16 Optimized Fast (measured)"
          },
          "standard": {
            "wer": null,
            "format": null,
            "multilingual": null,
            "speed_x": null,
            "j_per_min": null,
            "energy_note": null,
            "memory_mb": null,
            "latency_ms": null,
            "measured": null,
            "engine": null,
            "recipe": {
              "layers": {
                "all": "affine-4 g64"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "withdrawn",
              "reasons": [
                "Standard now computes in FP16 like mlx-whisper; the earlier Float32 Standard figures were withdrawn and this cell will be measured after 2.0."
              ],
              "baseline": "tier16 withdrawn Float32 Standard (measured build 55cb080, built from 77be9f2); not the shipped FP16 Standard"
            },
            "build_provenance": {
              "measured": null,
              "recipe": "builds.shipped",
              "bridge": "builds.bridge",
              "withdrawn_from": "builds.measured"
            },
            "not_measured_reason": "Standard now computes in FP16 like mlx-whisper; the earlier Float32 Standard figures were withdrawn and this cell will be measured after 2.0."
          },
          "optimized_exact": {
            "wer": null,
            "format": null,
            "multilingual": null,
            "speed_x": null,
            "j_per_min": null,
            "energy_note": null,
            "memory_mb": null,
            "latency_ms": null,
            "measured": null,
            "engine": null,
            "recipe": {
              "layers": {
                "all": "affine-4 g64"
              },
              "kernels": [
                "decoder",
                "fused_decode"
              ],
              "inexact": [],
              "gate_revision": "whisper-4",
              "env": {}
            },
            "gate": {
              "status": "withdrawn",
              "reasons": [
                "Exact now equals Fast for Whisper; not measured separately yet."
              ],
              "baseline": "tier16 withdrawn Float32 Standard (measured build 55cb080, built from 77be9f2); not the shipped FP16 Standard"
            },
            "build_provenance": {
              "measured": null,
              "recipe": "builds.shipped",
              "bridge": "builds.bridge",
              "withdrawn_from": "builds.measured"
            },
            "not_measured_reason": "Exact now equals Fast for Whisper; not measured separately yet."
          },
          "optimized_fast": {
            "wer": 17.1,
            "format": 8.17,
            "multilingual": {
              "mean": 14.03,
              "macro_wer": 13.34,
              "macro_cer": 15.41,
              "coverage": 9,
              "by_language": {
                "pl": 7.19,
                "de": 8.81,
                "fr": 21.8,
                "es": 17.02,
                "sv": 12.26,
                "tr": 12.96,
                "ja": 3.49,
                "zh": 21.52,
                "ko": 21.23
              }
            },
            "speed_x": 54.4,
            "j_per_min": 66.023,
            "energy_note": "median of 3 clean brackets (66.009–66.389 J/min)",
            "memory_mb": 2123,
            "latency_ms": {
              "p50": 164.6,
              "p95": 318.3,
              "n": 133,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-4 g64"
              },
              "kernels": [
                "decoder",
                "fused_decode"
              ],
              "inexact": [],
              "gate_revision": "whisper-4",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +0.10 pt vs 16 (limit 0.10)",
                "2 clips empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "2 clips empty or cut short where 16 had the words"
                ]
              },
              "baseline": "tier16 withdrawn Float32 Standard (measured build 55cb080, built from 77be9f2); not the shipped FP16 Standard"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_fast"
          }
        }
      }
    },
    "whisper-large-v3-turbo": {
      "noise_pt": 0.02,
      "tolerance_pt": 0.1,
      "noise_ml_pt": 0.17,
      "tolerance_ml_pt": 0.22,
      "tiers": {
        "16": {
          "precision": "FP16",
          "presence": {
            "offered": true,
            "reasons": [],
            "baseline": "tier16 Optimized Fast (measured)"
          },
          "gate": {
            "status": "pass",
            "reasons": [],
            "loss": [],
            "baseline": "tier16 Optimized Fast (measured)"
          },
          "standard": {
            "wer": null,
            "format": null,
            "multilingual": null,
            "speed_x": null,
            "j_per_min": null,
            "energy_note": null,
            "memory_mb": null,
            "latency_ms": null,
            "disk_mb": null,
            "measured": null,
            "engine": null,
            "recipe": {
              "layers": {
                "all": "fp16"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "withdrawn",
              "reasons": [
                "Standard now computes in FP16 like mlx-whisper; the earlier Float32 Standard figures were withdrawn and this cell will be measured after 2.0."
              ],
              "baseline": "tier16 withdrawn Float32 Standard (measured build 55cb080, built from 77be9f2); not the shipped FP16 Standard"
            },
            "build_provenance": {
              "measured": null,
              "recipe": "builds.shipped",
              "bridge": "builds.bridge",
              "withdrawn_from": "builds.measured"
            },
            "not_measured_reason": "Standard now computes in FP16 like mlx-whisper; the earlier Float32 Standard figures were withdrawn and this cell will be measured after 2.0."
          },
          "optimized_exact": {
            "wer": null,
            "format": null,
            "multilingual": null,
            "speed_x": null,
            "j_per_min": null,
            "energy_note": null,
            "memory_mb": null,
            "latency_ms": null,
            "disk_mb": null,
            "measured": null,
            "engine": null,
            "recipe": {
              "layers": {
                "all": "fp16"
              },
              "kernels": [
                "decoder"
              ],
              "inexact": [],
              "gate_revision": "whisper-4",
              "env": {}
            },
            "gate": {
              "status": "withdrawn",
              "reasons": [
                "Exact now equals Fast for Whisper; not measured separately yet."
              ],
              "baseline": "tier16 withdrawn Float32 Standard (measured build 55cb080, built from 77be9f2); not the shipped FP16 Standard"
            },
            "build_provenance": {
              "measured": null,
              "recipe": "builds.shipped",
              "bridge": "builds.bridge",
              "withdrawn_from": "builds.measured"
            },
            "not_measured_reason": "Exact now equals Fast for Whisper; not measured separately yet."
          },
          "optimized_fast": {
            "wer": 16.57,
            "format": 7.43,
            "multilingual": {
              "mean": 14.83,
              "macro_wer": 14.82,
              "macro_cer": 14.85,
              "coverage": 9,
              "by_language": {
                "pl": 7.61,
                "de": 9.71,
                "fr": 19.97,
                "es": 14.27,
                "sv": 23.87,
                "tr": 13.51,
                "ja": 3.49,
                "zh": 20.88,
                "ko": 20.17
              }
            },
            "speed_x": 113.7,
            "j_per_min": 37.183,
            "energy_note": "median of 3 clean brackets (37.134–37.339 J/min)",
            "memory_mb": 2522,
            "latency_ms": {
              "p50": 82.6,
              "p95": 127.1,
              "n": 133,
              "kind": "segment"
            },
            "disk_mb": 1619,
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-01",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "fp16"
              },
              "kernels": [
                "decoder"
              ],
              "inexact": [],
              "gate_revision": "whisper-4",
              "env": {}
            },
            "gate": {
              "status": "pass",
              "reasons": [],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 withdrawn Float32 Standard (measured build 55cb080, built from 77be9f2); not the shipped FP16 Standard"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_fast"
          }
        },
        "8": {
          "precision": "8b",
          "presence": {
            "offered": true,
            "reasons": [],
            "baseline": "tier16 Optimized Fast (measured)"
          },
          "gate": {
            "status": "pass",
            "reasons": [],
            "loss": [],
            "baseline": "tier16 Optimized Fast (measured)"
          },
          "standard": {
            "wer": null,
            "format": null,
            "multilingual": null,
            "speed_x": null,
            "j_per_min": null,
            "energy_note": null,
            "memory_mb": null,
            "latency_ms": null,
            "measured": null,
            "engine": null,
            "recipe": {
              "layers": {
                "all": "affine-8 g64",
                "model.encoder": "fp16"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "withdrawn",
              "reasons": [
                "Standard now computes in FP16 like mlx-whisper; the earlier Float32 Standard figures were withdrawn and this cell will be measured after 2.0."
              ],
              "baseline": "tier16 withdrawn Float32 Standard (measured build 55cb080, built from 77be9f2); not the shipped FP16 Standard"
            },
            "build_provenance": {
              "measured": null,
              "recipe": "builds.shipped",
              "bridge": "builds.bridge",
              "withdrawn_from": "builds.measured"
            },
            "not_measured_reason": "Standard now computes in FP16 like mlx-whisper; the earlier Float32 Standard figures were withdrawn and this cell will be measured after 2.0."
          },
          "optimized_exact": {
            "wer": null,
            "format": null,
            "multilingual": null,
            "speed_x": null,
            "j_per_min": null,
            "energy_note": null,
            "memory_mb": null,
            "latency_ms": null,
            "measured": null,
            "engine": null,
            "recipe": {
              "layers": {
                "all": "affine-8 g64",
                "model.encoder": "fp16"
              },
              "kernels": [
                "decoder",
                "fused_decode"
              ],
              "inexact": [],
              "gate_revision": "whisper-4",
              "env": {}
            },
            "gate": {
              "status": "withdrawn",
              "reasons": [
                "Exact now equals Fast for Whisper; not measured separately yet."
              ],
              "baseline": "tier16 withdrawn Float32 Standard (measured build 55cb080, built from 77be9f2); not the shipped FP16 Standard"
            },
            "build_provenance": {
              "measured": null,
              "recipe": "builds.shipped",
              "bridge": "builds.bridge",
              "withdrawn_from": "builds.measured"
            },
            "not_measured_reason": "Exact now equals Fast for Whisper; not measured separately yet."
          },
          "optimized_fast": {
            "wer": 16.52,
            "format": 7.46,
            "multilingual": {
              "mean": 14.8,
              "macro_wer": 14.77,
              "macro_cer": 14.83,
              "coverage": 9,
              "by_language": {
                "pl": 7.61,
                "de": 9.89,
                "fr": 20.05,
                "es": 14.36,
                "sv": 23.23,
                "tr": 13.51,
                "ja": 3.49,
                "zh": 20.88,
                "ko": 20.14
              }
            },
            "speed_x": 128.9,
            "j_per_min": 35.563,
            "energy_note": "median of 3 clean brackets (35.526–35.583 J/min)",
            "memory_mb": 2574,
            "latency_ms": {
              "p50": 74.1,
              "p95": 105.5,
              "n": 133,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-02",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-8 g64",
                "model.encoder": "fp16"
              },
              "kernels": [
                "decoder",
                "fused_decode"
              ],
              "inexact": [],
              "gate_revision": "whisper-4",
              "env": {}
            },
            "gate": {
              "status": "pass",
              "reasons": [],
              "presence": {
                "offered": true,
                "reasons": []
              },
              "baseline": "tier16 withdrawn Float32 Standard (measured build 55cb080, built from 77be9f2); not the shipped FP16 Standard"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_fast"
          }
        },
        "4": {
          "precision": "4b",
          "presence": {
            "offered": false,
            "reasons": [
              "1 clip empty or cut short where 16 had the words"
            ],
            "baseline": "tier16 Optimized Fast (measured)"
          },
          "gate": {
            "status": "fail",
            "reasons": [
              "English WER +0.39 pt vs 16 (limit 0.10)",
              "multilingual mean +0.23 pt vs 16 (limit 0.22)",
              "Turkish +2.66 pt vs 16 (limit 2.0)",
              "format CER +0.70 pt vs 16 (limit 0.10)",
              "1 clip empty or cut short where 16 had the words (limit 0)"
            ],
            "loss": [
              "English WER +0.39 pt",
              "multilingual mean +0.23 pt",
              "Turkish +2.66 pt",
              "format CER +0.70 pt"
            ],
            "baseline": "tier16 Optimized Fast (measured)"
          },
          "standard": {
            "wer": null,
            "format": null,
            "multilingual": null,
            "speed_x": null,
            "j_per_min": null,
            "energy_note": null,
            "memory_mb": null,
            "latency_ms": null,
            "measured": null,
            "engine": null,
            "recipe": {
              "layers": {
                "all": "affine-4 g64"
              },
              "kernels": [],
              "inexact": [],
              "gate_revision": "stock",
              "env": {}
            },
            "gate": {
              "status": "withdrawn",
              "reasons": [
                "Standard now computes in FP16 like mlx-whisper; the earlier Float32 Standard figures were withdrawn and this cell will be measured after 2.0."
              ],
              "baseline": "tier16 withdrawn Float32 Standard (measured build 55cb080, built from 77be9f2); not the shipped FP16 Standard"
            },
            "build_provenance": {
              "measured": null,
              "recipe": "builds.shipped",
              "bridge": "builds.bridge",
              "withdrawn_from": "builds.measured"
            },
            "not_measured_reason": "Standard now computes in FP16 like mlx-whisper; the earlier Float32 Standard figures were withdrawn and this cell will be measured after 2.0."
          },
          "optimized_exact": {
            "wer": null,
            "format": null,
            "multilingual": null,
            "speed_x": null,
            "j_per_min": null,
            "energy_note": null,
            "memory_mb": null,
            "latency_ms": null,
            "measured": null,
            "engine": null,
            "recipe": {
              "layers": {
                "all": "affine-4 g64"
              },
              "kernels": [
                "decoder",
                "fused_decode"
              ],
              "inexact": [],
              "gate_revision": "whisper-4",
              "env": {}
            },
            "gate": {
              "status": "withdrawn",
              "reasons": [
                "Exact now equals Fast for Whisper; not measured separately yet."
              ],
              "baseline": "tier16 withdrawn Float32 Standard (measured build 55cb080, built from 77be9f2); not the shipped FP16 Standard"
            },
            "build_provenance": {
              "measured": null,
              "recipe": "builds.shipped",
              "bridge": "builds.bridge",
              "withdrawn_from": "builds.measured"
            },
            "not_measured_reason": "Exact now equals Fast for Whisper; not measured separately yet."
          },
          "optimized_fast": {
            "wer": 16.96,
            "format": 8.14,
            "multilingual": {
              "mean": 15.06,
              "macro_wer": 15.13,
              "macro_cer": 14.92,
              "coverage": 9,
              "by_language": {
                "pl": 7.98,
                "de": 10.61,
                "fr": 18.62,
                "es": 15.48,
                "sv": 21.94,
                "tr": 16.17,
                "ja": 2.92,
                "zh": 21.81,
                "ko": 20.02
              }
            },
            "speed_x": 132.7,
            "j_per_min": 38.109,
            "energy_note": "median of 3 clean brackets (38.076–38.139 J/min)",
            "memory_mb": 1743,
            "latency_ms": {
              "p50": 72.7,
              "p95": 99.2,
              "n": 133,
              "kind": "segment"
            },
            "measured": {
              "hardware": "Apple M5 Max, macOS 26.6",
              "date": "2026-10-02",
              "suite": "v2",
              "audio_min": 239.7,
              "performance_suite": "v2-quick"
            },
            "engine": "optimized",
            "recipe": {
              "layers": {
                "all": "affine-4 g64"
              },
              "kernels": [
                "decoder",
                "fused_decode"
              ],
              "inexact": [],
              "gate_revision": "whisper-4",
              "env": {}
            },
            "gate": {
              "status": "fail",
              "reasons": [
                "English WER +0.45 pt vs 16 (limit 0.10)",
                "multilingual mean +0.41 pt vs 16 (limit 0.22)",
                "Turkish +2.55 pt vs 16 (limit 2.0)",
                "format CER +0.71 pt vs 16 (limit 0.10)",
                "1 clip empty or cut short where 16 had the words (limit 0)"
              ],
              "presence": {
                "offered": false,
                "reasons": [
                  "1 clip empty or cut short where 16 had the words"
                ]
              },
              "baseline": "tier16 withdrawn Float32 Standard (measured build 55cb080, built from 77be9f2); not the shipped FP16 Standard"
            },
            "build_provenance": {
              "measured": "builds.measured",
              "recipe": "builds.shipped",
              "bridge": "builds.bridge"
            }
          },
          "display_cells": {
            "standard": "standard",
            "optimized_exact": "optimized_exact",
            "optimized_fast": "optimized_fast"
          }
        }
      }
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
  },
  "default_on_twins": {
    "table": false,
    "note": "Historical pre-flip, levers-off comparison; not the shipped default recipe.",
    "rows": [
      {
        "cell": "parakeet-v3:8b",
        "twin": "parakeet-v3:8b-nolever",
        "levers": {
          "VELLA_PARAKEET_INT8": "1"
        },
        "inexact_levers": [
          "VELLA_PARAKEET_INT8"
        ],
        "accuracy_measured": true,
        "accuracy_reason": "full-v2 measured: inexact lever(s) VELLA_PARAKEET_INT8 change tokens",
        "with_levers": {
          "speed_x": 504.4,
          "j_per_min": 5.405,
          "memory_mb": 1342,
          "wer": 16.3,
          "format": 7.85,
          "ml_mean": 20.94
        },
        "without_levers": {
          "speed_x": 353.1,
          "j_per_min": 8.897,
          "memory_mb": 1870,
          "wer": 16.35,
          "format": 7.81,
          "ml_mean": 21.05
        },
        "delta": {
          "speed_pct": 42.8,
          "j_per_min_pct": -39.2,
          "memory_mb": -528,
          "wer_pt": -0.05,
          "ml_pt": -0.11
        }
      },
      {
        "cell": "parakeet-v3:4b",
        "twin": "parakeet-v3:4b-nolever",
        "levers": {
          "VELLA_PARAKEET_INT4": "1"
        },
        "inexact_levers": [
          "VELLA_PARAKEET_INT4"
        ],
        "accuracy_measured": true,
        "accuracy_reason": "full-v2 measured: inexact lever(s) VELLA_PARAKEET_INT4 change tokens",
        "with_levers": {
          "speed_x": 512.3,
          "j_per_min": 5.202,
          "memory_mb": 1088,
          "wer": 16.95,
          "format": 7.69,
          "ml_mean": 20.77
        },
        "without_levers": {
          "speed_x": 358.6,
          "j_per_min": 8.801,
          "memory_mb": 1633,
          "wer": 16.9,
          "format": 7.69,
          "ml_mean": 20.68
        },
        "delta": {
          "speed_pct": 42.9,
          "j_per_min_pct": -40.9,
          "memory_mb": -545,
          "wer_pt": 0.05,
          "ml_pt": 0.09
        }
      },
      {
        "cell": "nemotron-3.5-streaming-0.6b:BF16",
        "twin": "nemotron-3.5-streaming-0.6b:BF16-nolever",
        "levers": {
          "VELLA_NEMO_JOINTBATCH": "1",
          "VELLA_NEMO_KEEPCACHE": "1"
        },
        "inexact_levers": [
          "VELLA_NEMO_JOINTBATCH"
        ],
        "accuracy_measured": true,
        "accuracy_reason": "full-v2 measured: inexact lever(s) VELLA_NEMO_JOINTBATCH change tokens",
        "with_levers": {
          "speed_x": 34.9,
          "j_per_min": 50.034,
          "memory_mb": 1655,
          "wer": 23.35,
          "format": 10.58,
          "ml_mean": 27.21
        },
        "without_levers": {
          "speed_x": 29.0,
          "j_per_min": 56.336,
          "memory_mb": 1615,
          "wer": 23.35,
          "format": 10.58,
          "ml_mean": 27.21
        },
        "delta": {
          "speed_pct": 20.3,
          "j_per_min_pct": -11.2,
          "memory_mb": 40,
          "wer_pt": 0.0,
          "ml_pt": 0.0
        }
      },
      {
        "cell": "nemotron-3.5-streaming-0.6b:8b",
        "twin": "nemotron-3.5-streaming-0.6b:8b-nolever",
        "levers": {
          "VELLA_NEMO_KEEPCACHE": "1"
        },
        "inexact_levers": [],
        "accuracy_measured": false,
        "accuracy_reason": "full-v2 reused from nemotron-3.5-streaming-0.6b:8b: lever set VELLA_NEMO_KEEPCACHE is exact (every switch also in Optimized Exact; token-exact self-test), so the transcripts are identical",
        "with_levers": {
          "speed_x": 38.4,
          "j_per_min": 43.071,
          "memory_mb": 1114,
          "wer": 23.44,
          "format": 10.55,
          "ml_mean": 27.37
        },
        "without_levers": {
          "speed_x": 32.6,
          "j_per_min": 48.759,
          "memory_mb": 1084,
          "wer": 23.44,
          "format": 10.55,
          "ml_mean": 27.37
        },
        "delta": {
          "speed_pct": 17.8,
          "j_per_min_pct": -11.7,
          "memory_mb": 30,
          "wer_pt": 0.0,
          "ml_pt": 0.0
        }
      },
      {
        "cell": "nemotron-3.5-streaming-0.6b:4b",
        "twin": "nemotron-3.5-streaming-0.6b:4b-nolever",
        "levers": {
          "VELLA_NEMO_KEEPCACHE": "1"
        },
        "inexact_levers": [],
        "accuracy_measured": false,
        "accuracy_reason": "full-v2 reused from nemotron-3.5-streaming-0.6b:4b: lever set VELLA_NEMO_KEEPCACHE is exact (every switch also in Optimized Exact; token-exact self-test), so the transcripts are identical",
        "with_levers": {
          "speed_x": 39.7,
          "j_per_min": 39.768,
          "memory_mb": 847,
          "wer": 32.8,
          "format": 16.18,
          "ml_mean": 36.07
        },
        "without_levers": {
          "speed_x": 32.9,
          "j_per_min": 41.452,
          "memory_mb": 841,
          "wer": 32.8,
          "format": 16.18,
          "ml_mean": 36.07
        },
        "delta": {
          "speed_pct": 20.7,
          "j_per_min_pct": -4.1,
          "memory_mb": 6,
          "wer_pt": 0.0,
          "ml_pt": 0.0
        }
      },
      {
        "cell": "parakeet-v3-ultra:BF16",
        "twin": "parakeet-v3-ultra:BF16-nolever",
        "levers": {
          "VELLA_PARAKEET_TAILBLOCK": "1"
        },
        "inexact_levers": [],
        "accuracy_measured": false,
        "accuracy_reason": "full-v2 reused from parakeet-v3-ultra:BF16: lever set VELLA_PARAKEET_TAILBLOCK is exact (every switch also in Optimized Exact; token-exact self-test), so the transcripts are identical",
        "with_levers": {
          "speed_x": 507.1,
          "j_per_min": 4.582,
          "memory_mb": 1792,
          "wer": 15.51,
          "format": 5.79,
          "ml_mean": 12.73
        },
        "without_levers": {
          "speed_x": 501.7,
          "j_per_min": 5.223,
          "memory_mb": 1903,
          "wer": 15.51,
          "format": 5.79,
          "ml_mean": 12.73
        },
        "delta": {
          "speed_pct": 1.1,
          "j_per_min_pct": -12.3,
          "memory_mb": -111,
          "wer_pt": 0.0,
          "ml_pt": 0.0
        }
      },
      {
        "cell": "parakeet-v3-ultra:8b",
        "twin": "parakeet-v3-ultra:8b-nolever",
        "levers": {
          "VELLA_PARAKEET_INT8": "1",
          "VELLA_PARAKEET_TAILBLOCK": "1"
        },
        "inexact_levers": [
          "VELLA_PARAKEET_INT8"
        ],
        "accuracy_measured": true,
        "accuracy_reason": "full-v2 measured: inexact lever(s) VELLA_PARAKEET_INT8 change tokens",
        "with_levers": {
          "speed_x": 515.0,
          "j_per_min": 5.349,
          "memory_mb": 1352,
          "wer": 15.46,
          "format": 5.81,
          "ml_mean": 12.96
        },
        "without_levers": {
          "speed_x": 359.8,
          "j_per_min": 9.025,
          "memory_mb": 1912,
          "wer": 15.46,
          "format": 5.77,
          "ml_mean": 12.86
        },
        "delta": {
          "speed_pct": 43.1,
          "j_per_min_pct": -40.7,
          "memory_mb": -560,
          "wer_pt": 0.0,
          "ml_pt": 0.1
        }
      },
      {
        "cell": "parakeet-v3-ultra:4b",
        "twin": "parakeet-v3-ultra:4b-nolever",
        "levers": {
          "VELLA_PARAKEET_INT4": "1",
          "VELLA_PARAKEET_TAILBLOCK": "1"
        },
        "inexact_levers": [
          "VELLA_PARAKEET_INT4"
        ],
        "accuracy_measured": true,
        "accuracy_reason": "full-v2 measured: inexact lever(s) VELLA_PARAKEET_INT4 change tokens",
        "with_levers": {
          "speed_x": 522.5,
          "j_per_min": 5.129,
          "memory_mb": 1094,
          "wer": 15.58,
          "format": 5.8,
          "ml_mean": 13.53
        },
        "without_levers": {
          "speed_x": 360.0,
          "j_per_min": 8.813,
          "memory_mb": 1657,
          "wer": 15.65,
          "format": 5.84,
          "ml_mean": 13.6
        },
        "delta": {
          "speed_pct": 45.1,
          "j_per_min_pct": -41.8,
          "memory_mb": -563,
          "wer_pt": -0.07,
          "ml_pt": -0.07
        }
      }
    ],
    "records": {
      "parakeet-v3:8b-nolever": {
        "wer": 16.35,
        "format": 7.81,
        "multilingual": {
          "mean": 21.05,
          "macro_wer": 21.05,
          "macro_cer": null,
          "coverage": 5,
          "by_language": {
            "pl": 8.47,
            "de": 12.32,
            "fr": 33.81,
            "es": 27.86,
            "sv": 22.8
          }
        },
        "speed_x": 353.1,
        "j_per_min": 8.897,
        "energy_note": "median of 3 clean brackets (8.834–8.905 J/min)",
        "memory_mb": 1870,
        "latency_ms": {
          "p50": 19.0,
          "p95": 29.4,
          "n": 188,
          "kind": "segment"
        },
        "disk_mb": null,
        "suite": "v2",
        "audio_min": 239.7,
        "date": "2026-10-03",
        "hardware": "Apple M5 Max, macOS 26.6",
        "engine": "optimized"
      },
      "parakeet-v3:4b-nolever": {
        "wer": 16.9,
        "format": 7.69,
        "multilingual": {
          "mean": 20.68,
          "macro_wer": 20.68,
          "macro_cer": null,
          "coverage": 5,
          "by_language": {
            "pl": 8.77,
            "de": 11.96,
            "fr": 30.23,
            "es": 26.83,
            "sv": 25.59
          }
        },
        "speed_x": 358.6,
        "j_per_min": 8.801,
        "energy_note": "median of 3 clean brackets (8.623–8.937 J/min)",
        "memory_mb": 1633,
        "latency_ms": {
          "p50": 18.8,
          "p95": 29.2,
          "n": 188,
          "kind": "segment"
        },
        "disk_mb": null,
        "suite": "v2",
        "audio_min": 239.7,
        "date": "2026-10-03",
        "hardware": "Apple M5 Max, macOS 26.6",
        "engine": "optimized"
      },
      "nemotron-3.5-streaming-0.6b:BF16-nolever": {
        "wer": 23.35,
        "format": 10.58,
        "multilingual": {
          "mean": 27.21,
          "macro_wer": 28.54,
          "macro_cer": 24.57,
          "coverage": 9,
          "by_language": {
            "pl": 23.75,
            "de": 19.51,
            "fr": 17.82,
            "es": 16.25,
            "sv": 41.72,
            "tr": 52.16,
            "ja": 14.27,
            "zh": 29.42,
            "ko": 30.03
          }
        },
        "speed_x": 29.0,
        "j_per_min": 56.336,
        "energy_note": "median of 3 clean brackets (56.259–56.547 J/min)",
        "memory_mb": 1615,
        "latency_ms": {
          "p50": 0.6,
          "p95": 10.4,
          "n": 15040,
          "kind": "packet",
          "chunk_p50": 8.7,
          "chunk_p95": 11.2
        },
        "disk_mb": 1277,
        "suite": "v2",
        "audio_min": 239.7,
        "date": "2026-10-03",
        "hardware": "Apple M5 Max, macOS 26.6",
        "engine": "optimized",
        "note": "engine: Self-tested on this Mac against stock MLX (same streamed text; the fused layer is within a small numeric tolerance)."
      },
      "nemotron-3.5-streaming-0.6b:8b-nolever": {
        "wer": 23.44,
        "format": 10.55,
        "multilingual": {
          "mean": 27.37,
          "macro_wer": 28.72,
          "macro_cer": 24.66,
          "coverage": 9,
          "by_language": {
            "pl": 24.24,
            "de": 18.62,
            "fr": 18.46,
            "es": 16.25,
            "sv": 41.29,
            "tr": 53.49,
            "ja": 14.14,
            "zh": 29.59,
            "ko": 30.26
          }
        },
        "speed_x": 32.6,
        "j_per_min": 48.759,
        "energy_note": "median of 3 clean brackets (48.371–49.362 J/min)",
        "memory_mb": 1084,
        "latency_ms": {
          "p50": 0.6,
          "p95": 8.9,
          "n": 15040,
          "kind": "packet",
          "chunk_p50": 7.8,
          "chunk_p95": 9.8
        },
        "disk_mb": null,
        "suite": "v2",
        "audio_min": 239.7,
        "date": "2026-10-03",
        "hardware": "Apple M5 Max, macOS 26.6",
        "engine": "optimized",
        "note": "engine: Self-tested on this Mac against stock MLX (same streamed text; the fused layer is within a small numeric tolerance)."
      },
      "nemotron-3.5-streaming-0.6b:4b-nolever": {
        "wer": 32.8,
        "format": 16.18,
        "multilingual": {
          "mean": 36.07,
          "macro_wer": 37.63,
          "macro_cer": 32.93,
          "coverage": 9,
          "by_language": {
            "pl": 36.85,
            "de": 28.24,
            "fr": 21.48,
            "es": 19.52,
            "sv": 55.27,
            "tr": 64.45,
            "ja": 24.73,
            "zh": 39.65,
            "ko": 34.42
          }
        },
        "speed_x": 32.9,
        "j_per_min": 41.452,
        "energy_note": "median of 3 clean brackets (40.911–42.258 J/min)",
        "memory_mb": 841,
        "latency_ms": {
          "p50": 0.6,
          "p95": 8.9,
          "n": 15040,
          "kind": "packet",
          "chunk_p50": 7.6,
          "chunk_p95": 10.0
        },
        "disk_mb": null,
        "suite": "v2",
        "audio_min": 239.7,
        "date": "2026-10-03",
        "hardware": "Apple M5 Max, macOS 26.6",
        "engine": "optimized",
        "note": "engine: Self-tested on this Mac against stock MLX (same streamed text; the fused layer is within a small numeric tolerance)."
      },
      "parakeet-v3-ultra:BF16-nolever": {
        "wer": 15.51,
        "format": 5.79,
        "multilingual": {
          "mean": 12.73,
          "macro_wer": 12.73,
          "macro_cer": null,
          "coverage": 5,
          "by_language": {
            "pl": 6.88,
            "de": 8.72,
            "fr": 16.55,
            "es": 13.67,
            "sv": 17.85
          }
        },
        "speed_x": 501.7,
        "j_per_min": 5.223,
        "energy_note": "median of 3 clean brackets (5.099–5.236 J/min)",
        "memory_mb": 1903,
        "latency_ms": {
          "p50": 13.5,
          "p95": 21.1,
          "n": 188,
          "kind": "segment"
        },
        "disk_mb": 1255,
        "suite": "v2",
        "audio_min": 239.7,
        "date": "2026-10-03",
        "hardware": "Apple M5 Max, macOS 26.6",
        "engine": "optimized"
      },
      "parakeet-v3-ultra:8b-nolever": {
        "wer": 15.46,
        "format": 5.77,
        "multilingual": {
          "mean": 12.86,
          "macro_wer": 12.86,
          "macro_cer": null,
          "coverage": 5,
          "by_language": {
            "pl": 6.94,
            "de": 8.81,
            "fr": 16.55,
            "es": 13.5,
            "sv": 18.49
          }
        },
        "speed_x": 359.8,
        "j_per_min": 9.025,
        "energy_note": "median of 3 clean brackets (9.014–9.125 J/min)",
        "memory_mb": 1912,
        "latency_ms": {
          "p50": 18.6,
          "p95": 28.7,
          "n": 188,
          "kind": "segment"
        },
        "disk_mb": null,
        "suite": "v2",
        "audio_min": 239.7,
        "date": "2026-10-03",
        "hardware": "Apple M5 Max, macOS 26.6",
        "engine": "optimized"
      },
      "parakeet-v3-ultra:4b-nolever": {
        "wer": 15.65,
        "format": 5.84,
        "multilingual": {
          "mean": 13.6,
          "macro_wer": 13.6,
          "macro_cer": null,
          "coverage": 5,
          "by_language": {
            "pl": 7.43,
            "de": 8.72,
            "fr": 16.95,
            "es": 14.27,
            "sv": 20.65
          }
        },
        "speed_x": 360.0,
        "j_per_min": 8.813,
        "energy_note": "median of 3 clean brackets (8.782–8.984 J/min)",
        "memory_mb": 1657,
        "latency_ms": {
          "p50": 18.6,
          "p95": 28.8,
          "n": 188,
          "kind": "segment"
        },
        "disk_mb": null,
        "suite": "v2",
        "audio_min": 239.7,
        "date": "2026-10-03",
        "hardware": "Apple M5 Max, macOS 26.6",
        "engine": "optimized"
      }
    }
  },
  "noise_floor": {
    "date": "2026-09-28",
    "note": "Per-family noise estimates of 2026-09-28 (not re-measured on the final build).",
    "families": {
      "parakeet-v3": {
        "noise_date": "2026-09-28",
        "noise_source": "per-family noise pair of 2026-09-28: BF16:stock-v2 vs BF16:v2",
        "noise_pt": 0.04,
        "noise_ml_pt": 0.15,
        "tolerance_pt": 0.1,
        "tolerance_ml_pt": 0.2
      },
      "qwen3-asr-1.7b": {
        "noise_date": "2026-09-28",
        "noise_source": "per-family noise pair of 2026-09-28: BF16:stock-v2 vs BF16:r8-v2",
        "noise_pt": 0.0,
        "noise_ml_pt": 0.0,
        "tolerance_pt": 0.1,
        "tolerance_ml_pt": 0.1
      },
      "nemotron-3.5-streaming-0.6b": {
        "noise_date": null,
        "noise_source": "no noise pair measured; floor tolerances",
        "noise_pt": null,
        "noise_ml_pt": null,
        "tolerance_pt": 0.1,
        "tolerance_ml_pt": 0.1
      },
      "parakeet-v3-ultra": {
        "noise_date": "2026-09-28",
        "noise_source": "per-family noise pair of 2026-09-28: BF16:stock-v2 vs BF16:v2",
        "noise_pt": 0.02,
        "noise_ml_pt": 0.0,
        "tolerance_pt": 0.1,
        "tolerance_ml_pt": 0.1
      },
      "qwen3-asr-0.6b": {
        "noise_date": "2026-09-28",
        "noise_source": "per-family noise pair of 2026-09-28: BF16:stock-v2 vs BF16:r8-v2",
        "noise_pt": 0.0,
        "noise_ml_pt": 0.0,
        "tolerance_pt": 0.1,
        "tolerance_ml_pt": 0.1
      },
      "whisper-large-v3": {
        "noise_date": null,
        "noise_source": "no noise pair measured; floor tolerances",
        "noise_pt": null,
        "noise_ml_pt": null,
        "tolerance_pt": 0.1,
        "tolerance_ml_pt": 0.1
      },
      "whisper-large-v3-turbo": {
        "noise_date": "2026-09-28",
        "noise_source": "per-family noise pair of 2026-09-28: FP16:seed-0x5eed-v2 vs FP16:seed-0x0b0e-v2",
        "noise_pt": 0.02,
        "noise_ml_pt": 0.17,
        "tolerance_pt": 0.1,
        "tolerance_ml_pt": 0.22
      }
    }
  },
  "builds": {
    "measured": {
      "commit": "55cb080",
      "built_from": "77be9f2",
      "worker_sha256": "8a215e827e5972ef9afb4db7cf57ea8f068006f40ef1510ccd66e6977546b99d",
      "tag": "full-8a215e827e59",
      "dates": [
        "2026-10-01",
        "2026-10-02"
      ],
      "macOS": "26.6",
      "chip": "M5 Max",
      "env_map_sha256": "f6b6918a5ede08b3dffa45f4540bc9c9c488f566da8ef63fd7860e0aa8723242"
    },
    "shipped": {
      "commit": "08203e24ebdf83004ca4d81daa03f678880898c2",
      "worker_source_commit": "08203e24ebdf83004ca4d81daa03f678880898c2",
      "worker_sha256": null,
      "commit_kind": "worker-source",
      "build_receipt": "verified CI artifact receipt (filled at publish)",
      "note": "Worker source is pinned; worker SHA256 is filled only from the verified CI artifact at publish, never a local candidate. Bundled pre-fill data records source only."
    },
    "bridge": {
      "evidence": "scoped CPU source/key/verdict bridge receipt (3 Oct 2026)",
      "summary": "Scoped source bridge: 83 protected paths, with 3 comment-only hunks allowed; separate source diff confirms Nemotron; gate keys 24/24 identical; measured-worker verdicts 24/24 match. Builds are not bit-reproducible; metallib identical.",
      "whisper_fast_token_identity": {
        "status": "pass",
        "evidence": "Whisper Fast token-identity receipt (3 Oct 2026)",
        "worker_source": "40a2eef",
        "suite": "v2-quick",
        "cells": 6,
        "clips_per_cell": 122,
        "token_identical_per_cell": 122,
        "engine": "optimized",
        "components": "decoder (+ fused_decode on 8b/4b); no encoder lever",
        "summary": "One gpulock run of the new 40a2eef build: large-v3 and turbo × FP16/8b/4b, each 122/122 clips token-identical to measured Fast transcripts."
      },
      "defaults": "defaults flipped to the measured lever sets (Toby, 3 Oct); default keys == measured verdict keys: 30/30; 0 mismatches outside Whisper (whisper-4 listed separately)"
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
      "native_dtype": "bfloat16",
      "tiers_offered": [
        "16",
        "8",
        "4"
      ],
      "download": {
        "repo": "selcukkubur/parakeet-ultra-mlx",
        "revision": "b554592c50b2a48471add2daa3d46fa9f00fef5e",
        "bytes": 1254840214,
        "convert_to": [
          "8",
          "4"
        ]
      },
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
          "floatModules": [
            "decoder",
            "joint"
          ],
          "floatShare": 0.0184,
          "architecture": "parakeet"
        },
        "4b": {
          "id": "parakeet-ultra-mlx-4bit-local",
          "derivedFrom": "BF16",
          "bits": 4,
          "groupSize": 64,
          "floatModules": [
            "decoder",
            "joint"
          ],
          "floatShare": 0.0184,
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
      "native_dtype": "float32",
      "tiers_offered": ["16", "8"],
      "download": {
        "repo": "animaslabs/parakeet-tdt-0.6b-v3-mlx",
        "revision": "b3f0e8a62787b5dd33ebf05be8a5db41661c5eb6",
        "bytes": 2509016021,
        "convert_to": [
          "16",
          "8",
          "4"
        ]
      },
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
          "stored": true,
          "architecture": "parakeet"
        },
        "8b": {
          "id": "parakeet-tdt-0.6b-v3-mlx-8bit",
          "derivedFrom": "BF16",
          "bits": 8,
          "groupSize": 64,
          "floatModules": [
            "decoder",
            "joint"
          ],
          "floatShare": 0.0184,
          "architecture": "parakeet"
        },
        "4b": {
          "id": "parakeet-tdt-0.6b-v3-mlx-4bit",
          "derivedFrom": "BF16",
          "bits": 4,
          "groupSize": 64,
          "floatModules": [
            "decoder",
            "joint"
          ],
          "floatShare": 0.0184,
          "architecture": "parakeet"
        }
      },
      "offered": true,
      "publisher": "NVIDIA",
      "released": 2025,
      "licence": "CC BY 4.0",
      "summary": "The unmodified Parakeet v3 that Ultra is post-trained from: the same 25 European languages, no others",
      "notes": "NVIDIA's Parakeet TDT 0.6B v3, released in August 2025: a FastConformer-TDT speech recognizer for 25 European languages. In Vella: dictation in those languages with the unmodified original that Parakeet v3 Ultra is post-trained from. MLX conversion by animaslabs, published as FP32; Vella converts it once to BF16 when you get it and keeps only the BF16 weights."
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
      "native_dtype": "bfloat16",
      "tiers_offered": [
        "16"
      ],
      "download": {
        "repo": "mlx-community/Qwen3-ASR-1.7B-bf16",
        "revision": "e1f6c266914abc5a46e8756e02580f834a6cf8a7",
        "bytes": 4080708834,
        "convert_to": [
          "8",
          "4"
        ]
      },
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
          "derivedFrom": "BF16",
          "bits": 8,
          "groupSize": 64,
          "architecture": "qwen3_asr"
        },
        "4b": {
          "id": "Qwen3-ASR-1.7B-4bit",
          "derivedFrom": "BF16",
          "bits": 4,
          "groupSize": 64,
          "architecture": "qwen3_asr"
        }
      },
      "offered": true,
      "publisher": "Qwen (Alibaba)",
      "released": 2026,
      "licence": "Apache-2.0",
      "summary": "Dictation in 30 languages, including Chinese, Japanese and Korean, which Parakeet lacks; slower than Parakeet",
      "notes": "Qwen3-ASR 1.7B from Alibaba's Qwen team, released in January 2026: speech recognition built on Qwen3-Omni for 30 languages and 22 Chinese dialects. In Vella: dictation in languages Parakeet lacks, such as Chinese, Japanese and Korean. MLX conversion by mlx-community; lower precisions are made on this Mac from it."
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
      "native_dtype": "bfloat16",
      "tiers_offered": [
        "16",
        "8"
      ],
      "download": {
        "repo": "mlx-community/Qwen3-ASR-0.6B-bf16",
        "revision": "eae2b51f96265328f1e7beced788adb0e4536f92",
        "bytes": 1569436915,
        "convert_to": [
          "8",
          "4"
        ]
      },
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
          "derivedFrom": "BF16",
          "bits": 8,
          "groupSize": 64,
          "architecture": "qwen3_asr"
        },
        "4b": {
          "id": "Qwen3-ASR-0.6B-4bit",
          "derivedFrom": "BF16",
          "bits": 4,
          "groupSize": 64,
          "architecture": "qwen3_asr"
        }
      },
      "offered": true,
      "publisher": "Qwen (Alibaba)",
      "released": 2026,
      "licence": "Apache-2.0",
      "summary": "The smaller Qwen3 ASR: the same 30 languages in less memory, a little less accurate than the 1.7B",
      "notes": "The smaller Qwen3-ASR from Alibaba's Qwen team, released with the 1.7B in January 2026. In Vella: the same 30 languages in less memory, for Macs with less RAM. MLX conversion by mlx-community; lower precisions are made on this Mac from it."
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
      "native_dtype": "float16",
      "tiers_offered": [
        "16",
        "8"
      ],
      "download": {
        "repo": "mlx-community/whisper-large-v3-asr-fp16",
        "revision": "f4b9d561e7f1a5c0587726ff7ff03da2cc80fcf9",
        "bytes": 3087748437,
        "convert_to": [
          "8",
          "4"
        ]
      },
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
          "derivedFrom": "FP16",
          "bits": 8,
          "groupSize": 64,
          "floatModules": [
            "model.encoder"
          ],
          "floatShare": 0.4081,
          "architecture": "whisper",
          "legacyIDs": [
            "imported-whisper-large-v3-q8"
          ]
        },
        "4b": {
          "id": "whisper-large-v3-asr-4bit",
          "derivedFrom": "FP16",
          "bits": 4,
          "groupSize": 64,
          "architecture": "whisper"
        }
      },
      "offered": true,
      "publisher": "OpenAI",
      "released": 2023,
      "licence": "Apache-2.0",
      "summary": "Dictation in about 100 languages, the most of any model here, from a family other than Parakeet and Qwen",
      "notes": "OpenAI's Whisper large-v3, released in November 2023: an encoder-decoder transformer trained on 5 million hours of weakly and pseudo-labeled audio. In Vella: dictation in about 100 languages, from a model family other than Parakeet and Qwen. MLX conversion by mlx-community; lower precisions are made on this Mac from it."
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
      "native_dtype": "float16",
      "tiers_offered": [
        "16",
        "8"
      ],
      "download": {
        "repo": "mlx-community/whisper-large-v3-turbo-asr-fp16",
        "revision": "624c19c9af5603fa73b83bce14d4aeea96156d18",
        "bytes": 1618634653,
        "convert_to": [
          "8",
          "4"
        ]
      },
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
          "derivedFrom": "FP16",
          "bits": 8,
          "groupSize": 64,
          "floatModules": [
            "model.encoder"
          ],
          "floatShare": 0.7797,
          "architecture": "whisper"
        },
        "4b": {
          "id": "whisper-large-v3-turbo-asr-4bit",
          "derivedFrom": "FP16",
          "bits": 4,
          "groupSize": 64,
          "architecture": "whisper"
        }
      },
      "offered": true,
      "publisher": "OpenAI",
      "released": 2024,
      "licence": "MIT",
      "summary": "Whisper large-v3 with 4 decoder layers instead of 32: the same languages, much faster, a little less accurate outside English",
      "notes": "OpenAI's Whisper large-v3 turbo, released in 2024: large-v3 pruned from 32 decoder layers to 4, then fine-tuned. In Vella: much faster dictation in the same languages. MLX conversion by mlx-community; lower precisions are made on this Mac from it."
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
      "native_dtype": "bfloat16",
      "tiers_offered": [
        "16",
        "8"
      ],
      "download": {
        "repo": "mlx-community/nemotron-3.5-asr-streaming-0.6b",
        "revision": "e550040c0478027ed679b2b6b0d055502c103663",
        "bytes": 1276706069,
        "convert_to": [
          "8",
          "4"
        ]
      },
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
          "derivedFrom": "BF16",
          "bits": 8,
          "groupSize": 64,
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
      "summary": "Transcribes 28 languages as the audio arrives, so Streaming mode types while you speak; not used for Dictation",
      "notes": "NVIDIA's Nemotron 3.5 ASR Streaming 0.6B, released in 2026: a cache-aware FastConformer-RNNT model that transcribes audio as it arrives, for 40 language-locales. In Vella: Streaming mode, typing text while you speak. MLX conversion by mlx-community; lower precisions are made on this Mac from it."
    }
  ]
};
