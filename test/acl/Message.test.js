
require('@openzeppelin/test-helpers');

const { expect } = require('chai');

const MessageMock = artifacts.require('MessageMock');

contract('Message', function(accounts) {
    describe('getMessage', function () {
        context('Empty message', function () {

            beforeEach(async function () {
                this.message = await MessageMock.new();
            });
            
            it('returns empyt message', async function () {
                expect(await this.message.getMessage());
            });
        });
    });
});