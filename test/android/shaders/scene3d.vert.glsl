// MABA test scene - vertex stage. Header (#version 300 es) prepended by the app.
layout(location = 0) in vec3 aPos;
layout(location = 1) in vec3 aNormal;
layout(location = 2) in vec2 aUV;
layout(location = 3) in float aMat;

uniform highp mat4 uVP;
uniform highp mat4 uModel;

out highp vec3 vWorld;
out mediump vec3 vNormal;
out mediump vec2 vUV;
flat out mediump float vMat;

void main()
{
    highp vec4 w = uModel * vec4(aPos, 1.0);
    vWorld = w.xyz;
    vNormal = mat3(uModel) * aNormal;
    vUV = aUV;
    vMat = aMat;
    gl_Position = uVP * w;
}