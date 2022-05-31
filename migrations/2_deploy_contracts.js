var MessageMock = artifacts.require("MessageMock");

module.exports = function(deployer) {
  deployer.deploy(MessageMock);
};