const { jestConfig } = require('@salesforce/sfdx-lwc-jest/config');

// .claude/worktrees/ holds full copies of the repo (one per branch an agent is working on). Without this,
// a run from the main clone also picks up every copy: 52 suites instead of 4 and duplicate-module warnings.
const ignoreAgentCopies = '<rootDir>/.claude/';

module.exports = {
    ...jestConfig,
    testPathIgnorePatterns: [...(jestConfig.testPathIgnorePatterns || ['/node_modules/']), ignoreAgentCopies],
    modulePathIgnorePatterns: [...(jestConfig.modulePathIgnorePatterns || []), ignoreAgentCopies],
    moduleNameMapper: {
        // sfdx-lwc-jest 7.9.0 has no lightning/modal stub; see jest-mocks/lightning/modal.js
        '^lightning/modal$': '<rootDir>/jest-mocks/lightning/modal.js'
    }
};
