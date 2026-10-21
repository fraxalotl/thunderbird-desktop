/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation

/// Converts a practical subset of LaTeX math to MathML for Insert › Math (Thunderbird uses
/// TeXZilla for the same job): fractions, roots, sub/superscripts, Greek letters and operators.
public enum LaTeX {
  public static func mathML(_ source: String, display: Bool = false) -> String {
    var parser = Parser(Array(source))
    let body = parser.parseSequence(until: nil)
    return "<math xmlns=\"http://www.w3.org/1998/Math/MathML\"\(display ? " display=\"block\"" : "")><mrow>\(body)</mrow></math>"
  }

  static let symbols: [String: String] = [
    "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "zeta": "ζ", "eta": "η", "theta": "θ",
    "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ",
    "tau": "τ", "upsilon": "υ", "phi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω", "Gamma": "Γ", "Delta": "Δ",
    "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
  ]

  static let operators: [String: String] = [
    "times": "×", "cdot": "⋅", "div": "÷", "pm": "±", "mp": "∓", "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥",
    "neq": "≠", "ne": "≠", "approx": "≈", "equiv": "≡", "sim": "∼", "infty": "∞", "partial": "∂", "nabla": "∇",
    "sum": "∑", "prod": "∏", "int": "∫", "oint": "∮", "rightarrow": "→", "to": "→", "leftarrow": "←",
    "Rightarrow": "⇒", "Leftarrow": "⇐", "leftrightarrow": "↔", "in": "∈", "notin": "∉", "subset": "⊂",
    "supset": "⊃", "subseteq": "⊆", "cup": "∪", "cap": "∩", "forall": "∀", "exists": "∃", "neg": "¬",
    "land": "∧", "lor": "∨", "ldots": "…", "cdots": "⋯", "prime": "′", "degree": "°",
  ]

  static let functions: Set<String> = ["sin", "cos", "tan", "log", "ln", "exp", "lim", "max", "min", "det"]

  struct Parser {
    let chars: [Character]
    var index = 0

    init(_ chars: [Character]) { self.chars = chars }

    static func escape(_ text: String) -> String {
      text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
    }

    mutating func skipSpaces() {
      while index < chars.count, chars[index] == " " { index += 1 }
    }

    mutating func parseSequence(until terminator: Character?) -> String {
      var output = ""
      while index < chars.count {
        skipSpaces()
        guard index < chars.count else { break }
        if let terminator, chars[index] == terminator {
          index += 1
          break
        }
        var atom = parseAtom()
        skipSpaces()
        var sub: String?
        var sup: String?
        while index < chars.count, chars[index] == "_" || chars[index] == "^" {
          let marker = chars[index]
          index += 1
          let script = parseAtom()
          if marker == "_" { sub = script } else { sup = script }
          skipSpaces()
        }
        switch (sub, sup) {
        case (let sub?, let sup?): atom = "<msubsup>\(atom)\(sub)\(sup)</msubsup>"
        case (let sub?, nil): atom = "<msub>\(atom)\(sub)</msub>"
        case (nil, let sup?): atom = "<msup>\(atom)\(sup)</msup>"
        default: break
        }
        output += atom
      }
      return output
    }

    mutating func parseGroup() -> String {
      skipSpaces()
      guard index < chars.count else { return "<mrow/>" }
      if chars[index] == "{" {
        index += 1
        return "<mrow>\(parseSequence(until: "}"))</mrow>"
      }
      return parseAtom()
    }

    mutating func parseAtom() -> String {
      skipSpaces()
      guard index < chars.count else { return "" }
      let char = chars[index]
      if char == "{" {
        index += 1
        return "<mrow>\(parseSequence(until: "}"))</mrow>"
      }
      if char == "\\" {
        index += 1
        var name = ""
        while index < chars.count, chars[index].isLetter {
          name.append(chars[index])
          index += 1
        }
        if name.isEmpty, index < chars.count {
          let symbol = String(chars[index])
          index += 1
          return "<mo>\(Self.escape(symbol))</mo>"
        }
        switch name {
        case "frac":
          let numerator = parseGroup()
          let denominator = parseGroup()
          return "<mfrac>\(numerator)\(denominator)</mfrac>"
        case "sqrt":
          skipSpaces()
          if index < chars.count, chars[index] == "[" {
            index += 1
            let degree = parseSequence(until: "]")
            return "<mroot>\(parseGroup())<mrow>\(degree)</mrow></mroot>"
          }
          return "<msqrt>\(parseGroup())</msqrt>"
        case "text", "mathrm":
          skipSpaces()
          var text = ""
          if index < chars.count, chars[index] == "{" {
            index += 1
            while index < chars.count, chars[index] != "}" {
              text.append(chars[index])
              index += 1
            }
            index += 1
          }
          return "<mtext>\(Self.escape(text))</mtext>"
        case "left", "right":
          return parseAtom()
        default:
          if let symbol = LaTeX.symbols[name] { return "<mi>\(symbol)</mi>" }
          if let symbol = LaTeX.operators[name] { return "<mo>\(symbol)</mo>" }
          if LaTeX.functions.contains(name) { return "<mi>\(name)</mi>" }
          return "<mi>\(Self.escape(name))</mi>"
        }
      }
      index += 1
      if char.isNumber {
        var number = String(char)
        while index < chars.count, chars[index].isNumber || chars[index] == "." {
          number.append(chars[index])
          index += 1
        }
        return "<mn>\(number)</mn>"
      }
      if char.isLetter { return "<mi>\(char)</mi>" }
      return "<mo>\(Self.escape(String(char)))</mo>"
    }
  }
}
