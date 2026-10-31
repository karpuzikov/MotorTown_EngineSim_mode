
    // MTES_BRIDGE_V1: slave the audio simulator to Motor Town when telemetry is live.
    // The simulation remains the genuine Engine Simulator combustion/audio engine.
    // Motor Town physics are untouched; this process only follows its crankshaft RPM.
    {
        static bool mtWasConnected = false;
        MtTelemetry mt;
        if (readMtTelemetry(mt)) {
            mtWasConnected = true;
            const bool on = mt.running && mt.rpm >= 50.0;
            m_simulator->getEngine()->getIgnitionModule()->m_enabled = on;
            m_simulator->m_starterMotor.m_enabled = false;
            m_simulator->m_dyno.m_enabled = on;
            m_simulator->m_dyno.m_hold = on;
            m_dynoSpeed = on ? units::rpm(mt.rpm) : 0.0;
            m_simulator->m_dyno.m_rotationSpeed = m_dynoSpeed;
            m_simulator->getTransmission()->changeGear(-1);
            m_simulator->getTransmission()->setClutchPressure(0.0);
            m_speedSetting = m_targetSpeedSetting = on ? mt.throttle : 0.0;
            m_iceEngine->setSpeedControl(m_speedSetting);
        }
        else if (mtWasConnected) {
            // Fail silent when the game closes or telemetry disappears.
            m_simulator->m_dyno.m_enabled = false;
            m_simulator->m_dyno.m_hold = false;
            m_simulator->m_starterMotor.m_enabled = false;
            m_simulator->getEngine()->getIgnitionModule()->m_enabled = false;
            m_speedSetting = m_targetSpeedSetting = 0.0;
            m_iceEngine->setSpeedControl(0.0);
        }
    }
