#include "../include/engine_sim_application.h"
#include "../include/mtes_runtime.h"
// MTES_RUNTIME_V1
void EngineSimApplication::initialize() {
    settings.WindowWidth = 1920;
    settings.WindowHeight = 1080;
    mtesRuntimeLog("Creating graphics/audio window; shaders=" + shaderPath);
    const ysError mtesWindowError = m_engine.CreateGameWindow(settings);
    if (mtesWindowError != ysError::None) {
        throw std::runtime_error("Graphics/audio initialization failed (Delta error " +
            std::to_string(static_cast<int>(mtesWindowError)) + "). Shader directory: " + shaderPath);
    }
    mtesRuntimeLog("Graphics/audio window initialized");
    mtesRuntimeLog("Loading graphics assets: " + m_assetPath);
    m_assetManager.CompileInterchangeFile((m_assetPath + "/assets").c_str(), 1.0f, true);
    m_assetManager.LoadSceneFile((m_assetPath + "/assets").c_str(), true);
    mtesRuntimeLog("Graphics assets loaded");
    mtesRuntimeLog("Compiling engine script: ../assets/main.mr (details in error_log.log)");
    const bool compiled = compiler.compile("../assets/main.mr");
#endif /* ATG_ENGINE_SIM_PIRANHA_ENABLED */

    if (engine == nullptr) {
        throw std::runtime_error("The engine script did not create an engine. See error_log.log in build-mtes.");
    }
    mtesRuntimeLog("Engine script loaded");

    if (vehicle == nullptr) {
    }
    mtesRuntimeLog("Starting simulated audio renderer");
    m_simulator->startAudioRenderingThread();
    mtesRuntimeLog("Simulated audio renderer started");
    m_audioSource->SetVolume(1.0f);
}
void EngineSimApplication::process(double frame_dt) {
    double speed = 1.0 / 1.0;
    if (m_engine.IsKeyDown(ysKey::Code::N1)) {
        speed = 1 / 10.0;
    }
    else if (m_engine.IsKeyDown(ysKey::Code::N2)) {
        speed = 1 / 100.0;
    }
    else if (m_engine.IsKeyDown(ysKey::Code::N3)) {
        speed = 1 / 200.0;
    }
    else if (m_engine.IsKeyDown(ysKey::Code::N4)) {
        speed = 1 / 500.0;
    }
    else if (m_engine.IsKeyDown(ysKey::Code::N5)) {
        speed = 1 / 1000.0;
    }

    if (m_engine.IsKeyDown(ysKey::Code::F1)) {
        m_displayAngle += frame_dt * 1.0f;
    }
    else if (m_engine.IsKeyDown(ysKey::Code::F2)) {
        m_displayAngle -= frame_dt * 1.0f;
    }
    else if (m_engine.ProcessKeyDown(ysKey::Code::F3)) {
        m_displayAngle = 0.0f;
    }

    m_simulator->setSimulationSpeed(speed);
}
void EngineSimApplication::run() {
    if (m_engine.ProcessKeyDown(ysKey::Code::Escape)) { ++actions; }
    if (m_engine.ProcessKeyDown(ysKey::Code::Return)) { ++actions; }
    if (m_engine.ProcessKeyDown(ysKey::Code::Tab)) { ++actions; }
    if (m_engine.ProcessKeyDown(ysKey::Code::F)) { ++actions; }
    if (!m_paused || m_engine.ProcessKeyDown(ysKey::Code::Right)) { ++actions; }
}
void EngineSimApplication::configure(const ApplicationSettings &settings) {
    m_applicationSettings = settings;

    if (settings.startFullscreen) {
        m_engine.GetGameWindow()->SetWindowStyle(ysWindow::WindowStyle::Fullscreen);
    }

    m_background = ysColor::srgbiToLinear(m_applicationSettings.colorBackground);
}
// MTES_BRIDGE_V1 stays intact
