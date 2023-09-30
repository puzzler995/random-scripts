import requests
from pathlib import Path
import os

category = "CATEGORY NAME"

directory_path = "PATH_TO_DIRECTORY_HERE"

api_key = "YOUR_API_KEY_HERE"

base_url = "https://INSTANCE_URL/api/"

url = base_url+"admin/emoji/list"

data = {
  "i": api_key,
  "query": category,
  "limit": 100
}

response = requests.post(url, json=data)

emojidata = None

if response.status_code == 200:
  print("Sucessfully fetched emoji list!")
  emojidata = response.json()
else: 
  print("failed to fetch emoji list!")
  print(response.json())

emojinames = []

while emojidata:

  lastId = None
  for emoji in emojidata:
    emojinames.append(emoji["name"])
    lastId = emoji["id"]
  
  data = {
    "i": api_key,
    "query": category,
    "limit": 100,
    "untilId": lastId
  }

  response = requests.post(url, json=data)

  if response.status_code == 200:
    print("Sucessfully fetched emoji list!")
    emojidata = response.json()
  else: 
    print("failed to fetch emoji list!")
    print(response.json())


directory = Path(directory_path)

file_list = []

for file in directory.glob("**/*"):
  if file.is_file():
    file_list.append(file)

list_to_add = [filename for filename in file_list if filename.stem not in emojinames]
newEmojiIds = []
for file in list_to_add:
  print(file.name)
  url = base_url+"drive/files/find"
  data = {
    "i": api_key,
    "name": file.name
  }
  fileId = None
  response = requests.post(url, json=data)

  if response.status_code == 200:
    print("Sucessfully fetched file list!")
  else:
    print("failed to fetch file list!")
    break
  if not response.json():
    print("File not found, uploading...")
    url = base_url+"drive/files/create"
    payload = {
      "i": api_key,
      "name": file.name
    }
    files = {
      "file": open(file, "rb")
    }
    response = requests.post(url, data=payload, files=files)

    if response.status_code == 200:
      print("Sucessfully uploaded file!")
    else:
      print("failed to upload file!")
      print(response.json())
      break
  fileId = response.json()["id"]
  
  url = base_url+"admin/emoji/add"
  data = {
    "i": api_key,
    "fileId": fileId
  }
  response = requests.post(url, json=data)
  if response.status_code == 200:
    print("Sucessfully created emoji!")
  else:
    print("failed to create emoji!")
    print(response.json())
    break

  emojiId = response.json()["id"]

  relative_path = os.path.relpath(file, directory)
  tags = relative_path.split(os.path.sep)

  if tags[0] == ".":
    tags.pop(0)

  if len(tags) >= 1:
    tags.pop(-1)

  url = base_url+"admin/emoji/update"
  data = {
    "i": api_key,
    "id": emojiId,
    "name": file.stem,
    "category": category,
    "aliases": tags
  }
  response = requests.post(url, json=data)
  if response.status_code == 204:
    print("Sucessfully updated emoji!")
  else:
    print("failed to update emoji!")
    print(response.json())
    break