// Every outbound destination the support menu offers, kept apart from the menu
// that renders them: a wrong one still draws as a perfectly ordinary row, so the
// wrongness only ever shows up in where people actually end up. Gathered here so
// the whole set can be read, and guarded, in one place.

const REPO = "https://github.com/rike4545/Cathode";

export const SUPPORT_LINKS = {
  starRepo: REPO,
  latestRelease: `${REPO}/releases/latest`,
  reportIssue: `${REPO}/issues/new?labels=bug`,
  requestFeature: `${REPO}/issues/new?labels=enhancement`,
  // A form, not an address: there is no public mailbox to publish.
  contact: "https://qualtricsxmm8q5gxrhq.qualtrics.com/jfe/form/SV_1TvkCrIKgaEYHPM",
  privacyPolicy: `${REPO}/blob/master/PRIVACY.md`,
  disclaimer: `${REPO}/blob/master/DISCLAIMER.md`,
};
