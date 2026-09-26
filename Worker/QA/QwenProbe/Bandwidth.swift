import Foundation
import MLX
func bandwidthProbe() {
    func timeit(_ name: String, bytes: Double, _ f: () -> MLXArray) {
        eval(f()); eval(f())
        let n = 20; let t = ProcessInfo.processInfo.systemUptime
        var outs: [MLXArray] = []
        for _ in 0..<n { outs.append(f()) }
        eval(outs)
        let dt = (ProcessInfo.processInfo.systemUptime - t) / Double(n)
        print(name, String(format: "%.3f ms  %.0f GB/s", dt*1000, bytes/dt/1e9))
    }
    let a = MLXRandom.normal([128, 1024, 1024]).asType(.bfloat16); eval(a)
    timeit("copy bf16 256MB (r+w)", bytes: 2*Double(a.nbytes)) { a * 2 }
    let w = MLXRandom.normal([16384, 8192]).asType(.bfloat16); eval(w)
    let x = MLXRandom.normal([1, 8192]).asType(.bfloat16); eval(x)
    timeit("gemv bf16 256MB", bytes: Double(w.nbytes)) { matmul(x, w.T) }
    let (wq, s, b) = quantized(w, groupSize: 64, bits: 4); eval(wq, s, b!)
    let qb = Double(wq.nbytes + s.nbytes + b!.nbytes)
    timeit("qmv 4b \(Int(qb/1e6))MB", bytes: qb) { quantizedMatmul(x, wq, scales: s, biases: b, transpose: true, groupSize: 64, bits: 4) }
    let (w8, s8, b8) = quantized(w, groupSize: 64, bits: 8); eval(w8, s8, b8!)
    let q8 = Double(w8.nbytes + s8.nbytes + b8!.nbytes)
    timeit("qmv 8b \(Int(q8/1e6))MB", bytes: q8) { quantizedMatmul(x, w8, scales: s8, biases: b8, transpose: true, groupSize: 64, bits: 8) }
}
