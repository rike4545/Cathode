import { describe, expect, it } from "vitest";
import { SUPPORT_LINKS } from "./supportLinks";

// The expected values are written out in full rather than built from REPO the
// way the source builds them. Sharing that constant would make this pass no
// matter what REPO became — precisely the substitution worth catching. Spelled
// out, changing any link takes a second deliberate edit here.
//
// `toEqual` on the whole object rather than key by key, so a row that appears or
// disappears fails too.
describe("support menu links", () => {
  it("point where they are meant to", () => {
    expect(SUPPORT_LINKS).toEqual({
      starRepo: "https://github.com/rike4545/Cathode",
      latestRelease: "https://github.com/rike4545/Cathode/releases/latest",
      reportIssue: "https://github.com/rike4545/Cathode/issues/new?labels=bug",
      requestFeature: "https://github.com/rike4545/Cathode/issues/new?labels=enhancement",
      contact: "https://qualtricsxmm8q5gxrhq.qualtrics.com/jfe/form/SV_1TvkCrIKgaEYHPM",
      privacyPolicy: "https://github.com/rike4545/Cathode/blob/master/PRIVACY.md",
      disclaimer: "https://github.com/rike4545/Cathode/blob/master/DISCLAIMER.md",
    });
  });

  it("publish no email address", () => {
    for (const link of Object.values(SUPPORT_LINKS)) {
      expect(link.startsWith("mailto:")).toBe(false);
    }
  });
});
