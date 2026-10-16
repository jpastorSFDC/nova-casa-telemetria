const { jestConfig } = require('@salesforce/sfdx-lwc-jest/config');

// .claude and .cursor hold full copies of the repo (one per git worktree); skipping them avoids duplicate-module warnings.
module.exports = {
    ...jestConfig,
    modulePathIgnorePatterns: ['<rootDir>/.localdevserver', '<rootDir>/.claude', '<rootDir>/.cursor'],
    testPathIgnorePatterns: ['/node_modules/', '<rootDir>/.claude/', '<rootDir>/.cursor/']
};
