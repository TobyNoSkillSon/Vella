#if VELLA_QUALIFICATION
    import Foundation
    import MLX
    import MLXNN
    final class QualificationReference {
        weak var value: AnyObject?
        init(_ value: AnyObject?) { self.value = value }
    }
    func qualificationReferences(_ model: AnyObject?) -> [(String, QualificationReference)] {
        var result = [("$model", QualificationReference(model))]
        if let module = model as? Module {
            result += module.parameters().flattened().map { ($0.0, QualificationReference($0.1)) }
        }
        return result
    }
#endif
