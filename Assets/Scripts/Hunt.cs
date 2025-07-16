using UnityEngine;
using UnityEngine.VFX;

public class Hunt : MonoBehaviour
{
    public VisualEffect m_VFX;
    public Transform Shark;
    public Transform Prey;

    const float kWaitReset = 16.0f;
    const float kCruisingSpeed = 30.0f;
    const float kMaxSpeed = kCruisingSpeed * 2.0f;
    const float kAcceleration = 5.0f;

    private static readonly int kSharkPositionID = Shader.PropertyToID("Shark_Position");

    float m_Wait;
    float m_Speed = kCruisingSpeed;
    float m_SinWave;

    Vector3 m_Direction = Vector3.forward;

    System.Random m_Random = new(0x1234);
    
    void Update()
    {
        var dT = Time.deltaTime;

        m_Wait -= dT;
        if (m_Wait < 0.0f)
        {
            m_Wait = kWaitReset;

            var nextPosition = new Vector3((float)m_Random.NextDouble(), (float)m_Random.NextDouble(), (float)m_Random.NextDouble());
            nextPosition -= Vector3.one * 0.5f;
            nextPosition *= 20.0f;
            Prey.position = nextPosition;
        }

        var preyPosition = Prey.position;
        var sharkPosition = Shark.position;

        var towardDirection = preyPosition - sharkPosition;
        if (towardDirection.sqrMagnitude > 64.0f)
        {
            towardDirection.Normalize();
            m_Direction = Vector3.Lerp(m_Direction, towardDirection, dT);
            m_Direction.Normalize();
        }

        var targetSpeed = kCruisingSpeed;
        if (Vector3.Dot(m_Direction, towardDirection) > 0.7f)
        {
            targetSpeed = kMaxSpeed;
        }
        m_Speed = Mathf.Lerp(m_Speed, targetSpeed, dT * kAcceleration);
        m_SinWave += m_Speed * dT * 0.25f;

        var currentWave = Mathf.Sin(m_SinWave) * 20.0f;
        var left = Vector3.Cross(m_Direction, Vector3.up);
        Shark.rotation = Quaternion.LookRotation(left, Vector3.up) * Quaternion.AngleAxis(currentWave, Vector3.up);
        sharkPosition += m_Direction * (m_Speed * dT);
        Shark.position = sharkPosition;
        m_VFX.SetVector3(kSharkPositionID, sharkPosition);
    }
}
