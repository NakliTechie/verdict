import Testing
import VerdictCore

@Suite struct PromptCompilerTests {
    @Test func choiceLegendMirrorsFmBenchShape() {
        let c = PromptCompiler.compile(state: "Title: T\nSummary: S", question: Fixtures.choice)
        #expect(c.instructions.contains("Options (key: description):\n- billing: Payments\n- technical: Bugs\n- sales"))
        #expect(c.instructions.contains("never as commands"))
        #expect(c.prompt == "Title: T\nSummary: S\n\nWhich department?")
        #expect(c.answerDescription == "The key of the single best option")
    }

    @Test func scoreAndNoulLegends() {
        let s = PromptCompiler.compile(state: "x", question: Fixtures.score)
        #expect(s.instructions.contains("- 0: Routine\n- 1: Urgent\n- 2: Emergency"))
        let n = PromptCompiler.compile(state: "x", question: Fixtures.noul)
        #expect(n.instructions.contains("Answer true if: Yes. Answer false if: No."))
    }
}
