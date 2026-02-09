class DirectionalLight {

    constructor(lightIntensity, lightColor, lightPos, focalPoint, lightUp, hasShadowMap, gl) {
        this.mesh = Mesh.cube(setTransform(0, 0, 0, 0.2, 0.2, 0.2, 0));
        this.mat = new EmissiveMaterial(lightIntensity, lightColor);
        this.lightPos = lightPos;
        this.focalPoint = focalPoint;
        this.lightUp = lightUp

        this.hasShadowMap = hasShadowMap;
        this.fbo = new FBO(gl);
        if (!this.fbo) {
            console.log("无法设置帧缓冲区对象");
            return;
        }
    }

    CalcLightMVP(translate, scale) {
        let lightMVP = mat4.create();
        let modelMatrix = mat4.create();
        let viewMatrix = mat4.create();
        let projectionMatrix = mat4.create();
    
        // 1. Model Matrix: 先缩放后平移
        mat4.translate(modelMatrix, modelMatrix, translate);
        mat4.scale(modelMatrix, modelMatrix, scale);
    
        // 2. View Matrix: 光源位置，看向原点(或focalPoint)，上方向
        mat4.lookAt(viewMatrix, this.lightPos, this.focalPoint, this.lightUp);
    
        // 3. Projection Matrix: 正交投影
        // 参数需要根据场景大小调整，作业框架中 [-150, 150] 通常能覆盖全场景
        // near 和 far 平面要足够容纳物体
        mat4.ortho(projectionMatrix, -100.0, 100.0, -100.0, 100.0, 0.1, 1024.0);
    
        // 4. 合成 MVP: P * V * M
        mat4.multiply(lightMVP, projectionMatrix, viewMatrix);
        mat4.multiply(lightMVP, lightMVP, modelMatrix);
    
        return lightMVP;
    }
}
