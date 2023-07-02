//
//  ViewController.swift
//  audiorecpro
//
//  Created by Pelle Fredrikson on 2023-06-24.
//
import Cocoa
import WebKit
import AVFoundation

class ViewController: NSViewController, AVCaptureFileOutputRecordingDelegate {
    
    @IBOutlet weak var playlistInputField: NSTextField!
    @IBOutlet weak var startButton: NSButton!
    
    var audioRecorder: AVAudioRecorder?
    var captureSession: AVCaptureSession?
    var audioOutput: AVCaptureAudioDataOutput?
    var currentTrackIndex = 0
    
    private let clientID = "e66500965388431a9efb491fb2ceddae"
    private let redirectURI = "audiop://callback" // Set your custom redirect URI here
    private let scopes = ["user-library-read", "playlist-read-private"] // Set the required scopes here
    
    private var webView: WKWebView?
    
    override func viewDidLoad() {
        super.viewDidLoad()
    }
    
    @IBAction func startButtonClicked(_ sender: NSButton) {
        let playlistID = playlistInputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !playlistID.isEmpty else {
            // Display an error message indicating that the playlist ID is empty
            return
        }
        
        authenticate(playlistID: playlistID)
    }
    
    private func authenticate(playlistID: String) {
        let authURL = "https://accounts.spotify.com/authorize?client_id=\(clientID)&response_type=code&redirect_uri=\(redirectURI)&scope=\(scopes.joined(separator: "%20"))"
        
        if let url = URL(string: authURL) {
            let webView = WKWebView(frame: view.bounds)
            webView.navigationDelegate = self
            webView.load(URLRequest(url: url))
            
            self.webView = webView
            view.addSubview(webView)
        }
    }
    
    private func handleCallback(url: URL, playlistID: String) {
        guard let code = extractCode(from: url) else {
            // Handle the error case when the code cannot be extracted from the URL
            return
        }
        
        // Exchange the authorization code for an access token
        exchangeCodeForToken(code: code, playlistID: playlistID)
    }
    
    
    private func extractCode(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }
        
        for queryItem in queryItems {
            if queryItem.name == "code" {
                return queryItem.value
            }
        }
        
        return nil
    }
    
    private func exchangeCodeForToken(code: String, playlistID: String) {
        let tokenURL = "https://accounts.spotify.com/api/token"
        
        // Create the request to exchange the code for an access token
        var request = URLRequest(url: URL(string: tokenURL)!)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        // Set the required parameters for the token exchange
        let parameters: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "client_secret": "bf84031cdfbe4ba98397b7edd7922eaa" // Replace with your actual client secret
        ]
        
        // Manually encode the parameters into a percent-encoded string
        let encodedString = percentEncodeParameters(parameters)
        request.httpBody = encodedString.data(using: .utf8)
        
        
        let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
            if let error = error {
                // Handle the error case when the token exchange fails
                print("Error exchanging code for token: \(error.localizedDescription)")
                return
            }
            
            if let data = data {
                // Parse the access token from the response data
                do {
                    let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
                    let accessToken = tokenResponse.access_token
                    // Use the access token for further API requests
                    
                    // Fetch the playlist information
                    self.fetchPlaylist(accessToken: accessToken, playlistID: playlistID)
                } catch {
                    print("Error decoding token response: \(error.localizedDescription)")
                }
            }
        }
        
        task.resume()
    }
    
    // Create a function to percent encode a dictionary
    func percentEncodeParameters(_ parameters: [String: Any]) -> String {
        var encodedString = ""
        for (key, value) in parameters {
            if let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let encodedValue = "\(value)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                if !encodedString.isEmpty {
                    encodedString += "&"
                }
                encodedString += "\(encodedKey)=\(encodedValue)"
            }
        }
        return encodedString
    }
    
    private func fetchPlaylist(accessToken: String, playlistID: String) {
        let playlistURL = "https://api.spotify.com/v1/playlists/\(playlistID)"
        
        var request = URLRequest(url: URL(string: playlistURL)!)
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
            // Handle the playlist data response
            // Parse the JSON data and extract the tracks
            
            if let error = error {
                print("Error fetching playlist: \(error.localizedDescription)")
                return
            }
            
            if let data = data {
                // Parse the playlist data
                do {
                    let playlistResponse = try JSONDecoder().decode(PlaylistResponse.self, from: data)
                    let tracks = playlistResponse.tracks.items
                    self.recordSongs(tracks: tracks)
                } catch {
                    print("Error decoding playlist response: \(error.localizedDescription)")
                }
            }
        }
        
        task.resume()
    }
    
    private func recordSongs(tracks: [Track]) {
        guard currentTrackIndex < tracks.count else {
            print("Recording finished for all tracks")
            return
        }
        
        let track = tracks[currentTrackIndex]
        let trackName = track.name
        let trackURI = track.uri
        
        // Set up the audio recording session
        captureSession = AVCaptureSession()
        guard let audioDevice = AVCaptureDevice.default(for: .audio) else {
            print("No audio device available.")
            return
        }
        
        do {
            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
            captureSession?.addInput(audioInput)
            
            audioOutput = AVCaptureAudioDataOutput()
            audioOutput?.setSampleBufferDelegate(self, queue: DispatchQueue.main)
            
            if let audioOutput = audioOutput, captureSession?.canAddOutput(audioOutput) == true {
                captureSession?.addOutput(audioOutput)
            }
            
            captureSession?.startRunning()
        } catch {
            print("Error setting up audio input: \(error.localizedDescription)")
            return
        }
        
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let audioFilename = documentsURL.appendingPathComponent("\(trackName).m4a")
        
        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: [:])
            audioRecorder?.record()
        } catch {
            print("Error setting up audio recording: \(error.localizedDescription)")
            return
        }
        
        // Fetch the album artwork for each track
        self.fetchAlbumArtwork(track: track, completion: { (imageData) in
            // Save the album artwork image
            let artworkFilename = documentsURL.appendingPathComponent("\(trackName).jpg")
            try? imageData.write(to: artworkFilename)
            
            // Stop recording the audio
            self.stopRecording()
            
            // Move to the next track
            self.currentTrackIndex += 1
            self.recordSongs(tracks: tracks)
        })
    }
    
    private func fetchAlbumArtwork(track: Track, completion: @escaping (Data) -> Void) {
        // Make an HTTP GET request to the Get a Track endpoint of the Spotify Web API
        // Fetch the album artwork for the track
        let imageURL = URL(string: track.albumArtworkURL)
        URLSession.shared.dataTask(with: imageURL!) { (data, response, error) in
            if let data = data {
                completion(data)
            }
        }.resume()
    }
    
    private func stopRecording() {
        guard let captureSession = captureSession, captureSession.isRunning else {
            return
        }
        
        captureSession.stopRunning()
        audioRecorder?.stop()
    }
}

extension ViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        //        self.view.window?.rootViewController?.dismiss(animated: true, completion: nil)
    }
    
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.absoluteString.hasPrefix(redirectURI) {
            let playlistID = playlistInputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            handleCallback(url: url, playlistID: playlistID)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

extension ViewController: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Process the captured audio sample buffer
    }
}

extension ViewController {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        // Recording started
    }
    
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if let error = error {
            print("Error recording audio: \(error.localizedDescription)")
        } else {
            // Recording finished successfully
            // Perform any post-processing tasks here
            // For example, start recording the next track
        }
    }
}

struct TokenResponse: Codable {
    let access_token: String
    // Additional properties from the token response can be added here
}

struct PlaylistResponse: Codable {
    let tracks: Tracks
}

struct Tracks: Codable {
    let items: [Track]
}

struct Track: Codable {
    let name: String
    let uri: String
    let albumArtworkURL: String
    // Additional properties from the track response can be added here
}
