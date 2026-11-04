//
//  ParserOnlyMain.swift
//  Fluxo
//
//  `PARSER_ONLY=1 Tools/SeriesCheck/run.sh`: the parser checks without the store.
//

@main
struct ParserOnly {
    static func main() {
        ParserChecks.runParserCases()
        ParserChecks.benchmarkParser()
    }
}
