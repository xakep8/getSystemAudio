const processor = require('./build/Release/audio_capture');

module.exports = {
    /** @returns {void} */
    startCapture: processor.startCapture,
    /** @returns {void} */
    stopCapture: processor.stopCapture,
    /** @returns {Buffer} */
    getAudioData: processor.setCallback
};