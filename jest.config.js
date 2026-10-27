const { jestConfig } = require('@salesforce/sfdx-lwc-jest/config');

module.exports = {
    ...jestConfig,
    moduleNameMapper: {
        // sfdx-lwc-jest 7.9.0 has no lightning/modal stub; see jest-mocks/lightning/modal.js
        '^lightning/modal$': '<rootDir>/jest-mocks/lightning/modal.js'
    }
};
